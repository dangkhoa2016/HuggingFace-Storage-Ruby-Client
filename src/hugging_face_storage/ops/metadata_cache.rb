# frozen_string_literal: true

module HuggingFaceStorage
  # Thread-safe in-memory cache for metadata entries.
  # @api private
  # :nodoc:
  class MetadataCache
    def initialize
      @cache = {}
      @mutex = Mutex.new
    end

    # Fetches a value by key, computing and caching it if absent.
    #
    # @param key [Object] cache key
    # @param default [Object] default value if key not found
    # @yield optional block to compute the value
    # @return [Object] cached or computed value
    def fetch(key, default = nil)
      @mutex.synchronize do
        return @cache[key] if @cache.key?(key)

        value = block_given? ? yield : default
        @cache[key] = value
      end
    end

    # Stores a value by key.
    #
    # @param key [Object] cache key
    # @param value [Object] value to store
    # @return [void]
    def store(key, value)
      @mutex.synchronize { @cache[key] = value }
    end

    # Removes a key from the cache.
    #
    # @param key [Object] cache key to remove
    # @return [void]
    def invalidate(key)
      @mutex.synchronize { @cache.delete(key) }
    end

    # Clears all entries from the cache.
    #
    # @return [void]
    def clear
      @mutex.synchronize { @cache.clear }
    end
  end
end
