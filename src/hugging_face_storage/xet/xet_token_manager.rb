# frozen_string_literal: true

module HuggingFaceStorage
  # Manages caching and lifecycle of Xet read/write tokens.
  class XetTokenManager
    # Default token time-to-live in seconds (50 minutes).
    DEFAULT_TOKEN_TTL = 50 * 60

    # Initializes a new XetTokenManager.
    #
    # @param api_client [ApiClient] the API client
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    def initialize(api_client:, logger: nil, config: nil)
      @api = api_client
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @write_token_cache = {}
      @write_token_mutex = Mutex.new
      @read_token_cache = {}
      @read_token_mutex = Mutex.new
    end

    # Fetches a write token, using cache if still valid.
    #
    # @param bucket_id [String] the bucket ID
    # @return [Hash{Symbol => String, Integer, nil}] token info with :endpoint, :token, :expiration
    def fetch_write_token(bucket_id)
      fetch_token(bucket_id, :get_xet_write_token, @write_token_cache, @write_token_mutex)
    end

    # Fetches a read token, using cache if still valid.
    #
    # @param bucket_id [String] the bucket ID
    # @return [Hash{Symbol => String, Integer, nil}] token info with :endpoint, :token, :expiration
    def fetch_read_token(bucket_id)
      fetch_token(bucket_id, :get_xet_read_token, @read_token_cache, @read_token_mutex)
    end

    # Invalidates the cached write token for a bucket.
    #
    # @param bucket_id [String] the bucket ID
    # @return [void]
    def invalidate_write_token(bucket_id)
      @write_token_mutex.synchronize { @write_token_cache.delete(bucket_id) }
    end

    # Invalidates the cached read token for a bucket.
    #
    # @param bucket_id [String] the bucket ID
    # @return [void]
    def invalidate_read_token(bucket_id)
      @read_token_mutex.synchronize { @read_token_cache.delete(bucket_id) }
    end

    private

    # Fetches a token from cache or API, with cache eviction if needed.
    #
    # @param bucket_id [String] the bucket ID
    # @param api_method [Symbol] API method to call
    # @param cache [Hash] the token cache
    # @param mutex [Mutex] the cache mutex
    # @return [Hash{Symbol => String, Integer, nil}] token info
    def fetch_token(bucket_id, api_method, cache, mutex)
      mutex.synchronize do
        cached = cache.delete(bucket_id)
        if cached && cached[:expiration] &&
           Time.now.to_i < cached[:expiration] - @config.token_expiry_buffer
          cache[bucket_id] = cached
          return cached.dup
        end

        info = @api.public_send(api_method, bucket_id)
        entry = info.merge(bucket_id: bucket_id)
        cache[bucket_id] = entry
        evict_if_needed(cache)
        entry.dup
      end
    end

    # Evicts the oldest entry from the cache if it exceeds the configured size limit.
    #
    # @param cache [Hash] the token cache
    # @return [void]
    def evict_if_needed(cache)
      max = @config.xet_token_cache_size
      cache.shift if cache.size > max
    end
  end
end
