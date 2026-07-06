# frozen_string_literal: true

module HuggingFaceStorage
  # Connection-pooling layer for Net::HTTP.
  class HttpPool
    # How often (in #release calls) to reap idle connections.
    # A higher value reduces mutex contention; a lower value cleans stale
    # connections more promptly. 5 is a balanced default for typical CLI/API
    # workloads.
    REAP_EVERY = 5

    # Initializes the connection pool.
    #
    # @param config [Configuration] the configuration object
    # @param logger [Logger, nil] the logger instance
    def initialize(config:, logger: nil)
      @config = config
      @logger = logger
      @connections = {}
      @pool_mutex = Mutex.new
      @reap_counter = 0
    end

    # Acquires a connection, yields it, and releases it back to the pool.
    #
    # @param uri [URI] the target URI
    # @yield [Net::HTTP] an active HTTP connection
    # @return [Object] result of the block
    def with_connection(uri)
      http = acquire(uri)
      http.start unless http.started?
      yield http
    ensure
      release(uri, http) if http
    end

    # Closes and removes all pooled connections.
    #
    # @return [void]
    def close_all_connections
      @pool_mutex.synchronize do
        @connections.each_value do |entry|
          entry[:http].finish
        rescue StandardError => e
          @logger&.warn("Failed to close HTTP connection: #{e.class}: #{e.message}")
        end
        @connections.clear
      end
    end

    # Closes connections idle longer than the configured timeout.
    #
    # @param now [Time] the current time (defaults to Time.now)
    # @return [Integer] number of connections reaped
    def reap_idle_connections(now = Time.now)
      reaped = 0
      @pool_mutex.synchronize do
        expired_keys = @connections.select do |_, entry|
          (now - entry[:last_used]) > @config.idle_timeout
        end.keys
        expired_keys.each do |key|
          entry = @connections.delete(key)
          entry[:http].finish if entry
          reaped += 1
        rescue StandardError => e
          @logger&.warn("Failed to reap idle connection: #{e.class}: #{e.message}")
          reaped += 1
        end
      end
      reaped
    end

    private

    attr_reader :connections, :pool_mutex

    # Builds a unique key for identifying connections by host, port, and scheme.
    #
    # @param uri [URI] the target URI
    # @return [String] pool key
    def pool_key(uri)
      "#{uri.host}:#{uri.port}:#{uri.scheme}"
    end

    # Acquires a connection from the pool or builds a new one.
    #
    # @param uri [URI] the target URI
    # @return [Net::HTTP] an HTTP connection
    def acquire(uri)
      cached = @pool_mutex.synchronize do
        key = pool_key(uri)
        entry = @connections.delete(key)
        if entry
          http = entry[:http]
          if (Time.now - entry[:last_used]) > @config.idle_timeout
            begin
              http.finish
            rescue StandardError => e
              @logger&.warn("Failed to close stale connection: #{e.class}: #{e.message}")
            end
            nil
          else
            http
          end
        end
      end
      cached || build_http(uri)
    end

    # Releases a connection back to the pool, periodically reaping idle connections.
    #
    # @param uri [URI] the target URI
    # @param http [Net::HTTP] the HTTP connection
    # @return [void]
    def release(uri, http)
      key = pool_key(uri)
      should_reap = false
      @pool_mutex.synchronize do
        @connections[key] = { http: http, last_used: Time.now }
        @reap_counter += 1
        should_reap = true if (@reap_counter % REAP_EVERY).zero?
      end
      reap_idle_connections if should_reap
    end

    # Builds and configures a new Net::HTTP connection for the given URI.
    #
    # @param uri [URI] the target URI
    # @return [Net::HTTP] a configured HTTP connection
    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      if http.use_ssl?
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true if http.respond_to?(:verify_hostname=)
      end
      http.connect_timeout = @config.open_timeout if http.respond_to?(:connect_timeout=) # steep:ignore
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http.write_timeout = @config.write_timeout
      http.keep_alive_timeout = @config.idle_timeout
      http
    end
  end
end
