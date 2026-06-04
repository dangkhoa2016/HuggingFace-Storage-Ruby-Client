# frozen_string_literal: true

module HuggingFaceStorage
  # Cooperative cancellation mechanism for long-running operations.
  class CancelToken
    # Creates a new cancel token.
    #
    # @param logger [Logger, nil] optional logger
    def initialize(logger: nil)
      @cancelled = false
      @mutex = Mutex.new
      @on_cancel = []
      @logger = logger || HuggingFaceStorage::NullLogger.new
    end

    # Triggers cancellation and invokes all registered callbacks.
    #
    # @return [self]
    def cancel!
      return self if frozen?

      callbacks = @mutex.synchronize do
        return self if @cancelled

        @cancelled = true
        @on_cancel.dup.tap { @on_cancel.clear }
      end

      callbacks.each do |cb|
        cb.call
      rescue StandardError => e
        @logger.error("Cancel callback failed: #{e.class}: #{e.message}")
      end
      self
    end

    # Returns whether cancellation has been requested.
    #
    # @return [Boolean] true if cancelled
    def cancelled?
      @cancelled
    end

    # Raises if cancellation has been requested.
    #
    # @raise [CancelledError] if cancelled
    def raise_if_cancelled!
      raise CancelledError, "Operation cancelled" if @cancelled
    end

    # Registers a callback to invoke on cancellation.
    #
    # @param block [Proc] the callback
    # @return [self]
    def on_cancel(&block)
      return self if frozen?

      should_call = false
      @mutex.synchronize do
        @on_cancel << block
        if @cancelled
          should_call = true
          @on_cancel.delete(block)
        end
      end
      if should_call
        begin
          yield
        rescue StandardError => e
          @logger.error("Cancel callback failed: #{e.class}: #{e.message}")
        end
      end
      self
    end

    # Removes a previously registered cancel callback.
    #
    # @param block [Proc] the callback to remove
    def cancel_subscription(block)
      @mutex.synchronize { @on_cancel.delete(block) }
    end

    # Returns a frozen no-op cancel token.
    #
    # @return [CancelToken] a frozen, never-cancelled token
    def self.none
      @none ||= new.freeze
    end
  end
end
