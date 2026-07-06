# frozen_string_literal: true

module HuggingFaceStorage
  # No-op metrics registry that discards all metric data.
  class NullMetricsRegistry
    # @return [nil]
    def increment(...)
      nil
    end
    # @return [nil]
    def gauge(...)
      nil
    end
    # @yield block to measure
    # @return [Object] block result
    def measure(...)
      yield
    end
    # @return [nil]
    def observe(...)
      nil
    end

    # Returns a frozen singleton instance.
    #
    # Reusing a single frozen instance avoids unnecessary object allocations
    # and ensures thread-safe sharing across all consumers.
    #
    # @return [NullMetricsRegistry] the frozen singleton
    def self.instance
      @instance ||= new.freeze
    end
  end
end
