# frozen_string_literal: true

module HuggingFaceStorage
  # Thread-safe metrics counter registry.
  class MetricsRegistry
    # Initializes an empty metrics registry.
    def initialize
      @counters = Hash.new(0)
      @mutex = Mutex.new
    end

    # Increments the named counter by +amount+.
    #
    # @param name [Symbol, String] counter name
    # @param amount [Numeric] amount to increment (default 1)
    # @return [void]
    def increment(name, amount = 1)
      @mutex.synchronize { @counters[name.to_sym] += amount }
    end

    # Returns the current value of the named counter.
    #
    # @param name [Symbol, String] counter name
    # @return [Integer] current count
    def counter(name)
      @mutex.synchronize { @counters[name.to_sym] }
    end

    # Returns a snapshot of all counters.
    #
    # @return [Hash] copy of all counter values
    def all
      @mutex.synchronize { @counters.dup }
    end

    # Resets all counters to zero.
    #
    # @return [void]
    def reset
      @mutex.synchronize { @counters.clear }
    end

    # Returns a hash with computed throughput (MB/s) when elapsed time is present.
    #
    # @return [Hash] counter data with optional :throughput_mb_per_sec
    def to_h
      snapshot = all
      # : Integer
      elapsed = snapshot.delete(:elapsed_seconds) || 0
      result = snapshot.dup
      if elapsed.positive?
        bytes = (snapshot[:bytes_uploaded] || 0) + (snapshot[:bytes_downloaded] || 0)
        result[:elapsed_seconds] = elapsed
        result[:throughput_mb_per_sec] = ((bytes.to_f / (1024 * 1024)) / elapsed).round(2)
      end
      result
    end
  end
end
