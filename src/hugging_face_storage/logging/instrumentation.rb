# frozen_string_literal: true

module HuggingFaceStorage
  # Mixin providing operation instrumentation with metrics and notifications.
  module Instrumentation
    # @return [Array<Symbol>] metric keys tracked by this instrumentation mixin
    METRIC_KEYS = %i[bytes_uploaded bytes_downloaded files xorbs shards operations].freeze

    # Hooks into the including class to prepend the InitializerOverride module.
    #
    # @param base [Class] the class including this module
    # @return [void]
    def self.included(base)
      base.prepend(InitializerOverride)
    end

    # Prepend module that ensures default null objects for logger, metrics, and notifications.
    module InitializerOverride
      # Wraps the original initializer to set defaults for instrumentation dependencies.
      #
      # @param args [Array] positional arguments
      # @param kwargs [Hash] keyword arguments
      # @param block [Proc, nil] optional block
      # @return [void]
      def initialize(*args, **kwargs, &block)
        super
        @logger ||= NullLogger.new
        @metrics_registry ||= NullMetricsRegistry.instance
        @notifications ||= NullNotifications.instance
      end
    end

    # Times the block, records metrics, and publishes a notification.
    #
    # @param name [String] operation name
    # @param payload [Hash] metric counters (bytes_uploaded, etc.)
    # @yield the operation to instrument
    # @return [Object] result of the block
    def instrument(name, payload = {}, &block)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = yield
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        record_metrics(payload, elapsed)
        @logger.debug { "  #{name} completed in #{elapsed.round(3)}s" }
        @notifications.publish(name, payload.merge(elapsed: elapsed, status: :success))
        result
      rescue StandardError => e
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        record_metrics(payload, elapsed)
        @notifications.publish(name, payload.merge(elapsed: elapsed, status: :error, error: e))
        raise
      end
    end

    # Records elapsed time and metric counters from the payload.
    #
    # @param payload [Hash] the operation payload
    # @param elapsed [Float] elapsed seconds
    # @return [void]
    def record_metrics(payload, elapsed)
      @metrics_registry.increment(:elapsed_seconds, elapsed)
      METRIC_KEYS.each do |key|
        @metrics_registry.increment(key, payload[key]) if payload[key]
      end
    end

    # Increments a metric counter.
    #
    # @param metric [Symbol] metric name
    # @param tags [Hash] metric tags
    # @param by [Numeric] increment amount (default 1)
    # @return [void]
    def track_increment(metric, tags: {}, by: 1)
      @metrics_registry.increment(metric, tags: tags, by: by)
    end

    # Records a gauge value.
    #
    # @param metric [Symbol] metric name
    # @param value [Numeric] gauge value
    # @param tags [Hash] metric tags
    # @return [void]
    def track_gauge(metric, value, tags: {})
      @metrics_registry.gauge(metric, value, tags: tags)
    end

    # Measures the duration of a block.
    #
    # @param metric [Symbol] metric name
    # @param tags [Hash] metric tags
    # @yield block to measure
    # @return [Object] block result
    def track_measure(metric, tags: {}, &block)
      @metrics_registry.measure(metric, tags: tags, &block)
    end

    # Publishes a notification event.
    #
    # @param event [String] event name
    # @param payload [Hash] event payload
    # @return [void]
    def publish(event, payload = {})
      @notifications.publish(event, payload)
    end
  end
end
