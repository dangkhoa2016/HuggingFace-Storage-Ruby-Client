# frozen_string_literal: true

module HuggingFaceStorage
  class Client
    # Builder for constructing a fully configured Client.
    class Builder
      DEFAULTS = {
        log_level: :info,
        log_format: :default,
        log_output: $stdout,
        log_color: :auto,
        debug_mode: false,
      }.freeze

      # Initializes a new Builder with optional overrides.
      #
      # @param options [Hash] initial option values
      def initialize(options = {})
        @options = DEFAULTS.merge(options)
      end

      %i[token namespace bucket config log_level log_format log_output log_color
         debug_mode metrics_registry notifications].each do |key|
        define_method(:"#{key}=") { |value| @options[key] = value }
      end

      # Builds a fully configured Client instance.
      #
      # @return [Client] the configured client
      def build
        validate!

        bucket_id    = "#{@options[:namespace]}/#{@options[:bucket]}"
        config       = build_config
        logger       = build_logger
        metrics      = @options[:metrics_registry] || NullMetricsRegistry.instance
        notifications = @options[:notifications] || NullNotifications.instance

        factory = ServiceFactory.new(
          config: config, logger: logger,
          metrics_registry: metrics, notifications: notifications,
          token: @options[:token], bucket_id: bucket_id
        )

        auth, api = factory.build_auth_and_transport
        xet_uploader, xet_downloader = factory.build_xet_services(api)
        same_bucket_copy, copy_pipeline, cross_repo_copy, source_iterator = factory.build_copy_services(api,
                                                                                                        xet_uploader)
        files = factory.build_file_services(xet_uploader, xet_downloader, api, same_bucket_copy, cross_repo_copy,
                                            copy_pipeline)
        directories = factory.build_directory_services(api, xet_uploader, xet_downloader, files, copy_pipeline,
                                                       source_iterator)

        Client.new(
          files: files, directories: directories, logger: logger,
          config: config, auth: auth, api: api, bucket_id: bucket_id,
          metrics_registry: metrics, notifications: notifications
        )
      end

      private

      # Validates that required options are present.
      #
      # @raise [ArgumentError] if namespace or bucket is missing
      # @return [void]
      def validate!
        raise ArgumentError, "namespace is required" if @options[:namespace].nil? || @options[:namespace].empty?
        raise ArgumentError, "bucket is required" if @options[:bucket].nil? || @options[:bucket].empty?
        raise ArgumentError, "token is required" if @options[:token].nil? || @options[:token].empty?
      end

      # Builds the configuration object.
      #
      # @return [Configuration]
      def build_config
        @options[:config] || Configuration.new(debug_mode: @options[:debug_mode])
      end

      # Builds the logger instance.
      #
      # @return [HFLogger]
      def build_logger
        HFLogger.new(
          level: @options[:log_level],
          format: @options[:log_format],
          output: @options[:log_output],
          color: @options[:log_color]
        )
      end
    end
  end
end
