# frozen_string_literal: true

module HuggingFaceStorage
  # No-op notification channel that discards all events.
  class NullNotifications
    # @return [nil]
    def subscribe(...)
      nil
    end

    # @return [nil]
    def publish(...)
      nil
    end

    # @return [Boolean] always false
    def subscribed?(...)
      false
    end

    # Returns a frozen singleton instance.
    #
    # Reusing a single frozen instance avoids unnecessary object allocations
    # and ensures thread-safe sharing across all consumers.
    #
    # @return [NullNotifications] the frozen singleton
    def self.instance
      @instance ||= new.freeze
    end
  end
end
