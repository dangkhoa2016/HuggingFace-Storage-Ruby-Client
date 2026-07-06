# frozen_string_literal: true

module HuggingFaceStorage
  # Pub/sub mixin for notification channels.
  module Subscribable
    # @param base [Class] the including class
    # @return [void]
    def self.included(base)
      base.prepend(Initialization)
    end

    # Hooks +initialize+ to set up subscriber state when the module is included.
    module Initialization
      # Injects subscriber initialization into the including class.
      def initialize(...)
        @subscribers = [] # : Array[Hash[Symbol, untyped]]
        @mutex = Mutex.new
        super
      end
    end

    # Returns a copy of the current subscriber list.
    #
    # @return [Array<Hash>] subscriber entries with :id, :pattern, :block
    def subscribers
      @mutex.synchronize { @subscribers.dup }
    end

    # Subscribes a block to events matching the optional +pattern+.
    #
    # @param pattern [String, Regexp, Array, nil] event filter
    # @param block [Proc] the callback
    # @return [String] subscriber id (for unsubscribe)
    def subscribe(pattern = nil, &block)
      raise ArgumentError, "subscriber must be a block" unless block

      entry = { pattern: pattern, block: block, id: SecureRandom.hex(8) } # : Hash[Symbol, untyped]
      @mutex.synchronize { @subscribers << entry }
      entry[:id]
    end

    # Removes a subscriber by +id+.
    #
    # @param id [String] subscriber id returned from subscribe
    # @return [void]
    def unsubscribe(id)
      @mutex.synchronize { @subscribers.reject! { |e| e[:id] == id } }
    end

    # Removes all subscribers.
    #
    # @return [void]
    def clear
      @mutex.synchronize { @subscribers = [] }
    end

    # Publishes an event to all matching subscribers.
    #
    # @param name [String] event name
    # @param payload [Hash] event payload
    # @return [void]
    def publish(name, payload)
      snapshot = @mutex.synchronize { @subscribers.dup }
      snapshot.each do |entry|
        next unless matches?(entry[:pattern], name)

        begin
          entry[:block].call(name, payload)
        rescue StandardError => e
          backtrace = e.backtrace&.first(3)&.join("; ") || "(no backtrace)"
          logger&.warn("[notifications] Subscriber error: #{e.class}: #{e.message} (#{backtrace})") ||
            warn("[notifications] Subscriber error: #{e.class}: #{e.message} (#{backtrace})")
        end
      end
    end

    private

    # @return [Logger, nil] the optional logger for error reporting
    def logger
      @logger
    end

    def matches?(pattern, name)
      return true if pattern.nil?

      case pattern
      when String then pattern == name
      when Regexp then pattern.match?(name)
      when Array  then pattern.include?(name)
      else false
      end
    end
  end

  # Global notification bus (module-level methods removed; use Channel for isolated instances).
  module Notifications
    # An isolated notification channel.
    class Channel
      include Subscribable
    end
  end
end
