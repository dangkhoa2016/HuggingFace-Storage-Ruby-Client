# frozen_string_literal: true

require_relative "builder"
require_relative "service_factory"

module HuggingFaceStorage
  # Entry point for the HuggingFace Storage API.
  # Orchestrates {FileManager}, {DirectoryManager}, {ApiClient}, and Xet subsystems.
  class Client
    # @return [FileManager] file management interface
    # @return [DirectoryManager] directory management interface
    # @return [String] the fully-qualified bucket ID (namespace/bucket)
    # @return [HFLogger] the client's logger instance
    # @return [Configuration] the client's configuration
    attr_reader :files, :directories, :bucket_id, :logger, :config

    # @return [Boolean] whether debug mode is enabled
    def debug_mode
      @config.debug_mode
    end

    class << self
      # Creates a new Client instance, auto-building via {Builder} when
      # +:namespace+ or +:bucket+ keyword arguments are provided.
      #
      # @param args [Array] positional arguments (passed to super)
      # @param kwargs [Hash] keyword arguments
      # @param block [Proc] optional block
      # @return [Client] a configured client instance
      def new(*args, **kwargs, &block)
        if kwargs.key?(:namespace) || kwargs.key?(:bucket)
          HuggingFaceStorage::Client::Builder.new(**kwargs).build
        else
          super
        end
      end
    end

    # Initializes a fully wired Client instance.
    #
    # @param files [FileManager] file management interface
    # @param directories [DirectoryManager] directory management interface
    # @param logger [HFLogger] logger instance
    # @param config [Configuration] configuration object
    # @param auth [Authentication] authentication instance
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier (namespace/bucket)
    # @param metrics_registry [MetricsRegistry, nil] optional metrics registry
    # @param notifications [Notifications::Channel, nil] optional notifications channel
    def initialize(files:, directories:, logger:, config:, auth:, api:,
                   bucket_id:, metrics_registry: nil, notifications: nil)
      @files = files
      @directories = directories
      @logger = logger
      @config = config
      @auth = auth
      @api = api
      @bucket_id = bucket_id
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Get metadata about the current bucket.
    # @return [Hash] raw API response (name, size, etc.)
    def bucket_info
      @logger.info("Fetching bucket info: #{@bucket_id}")
      result = @api.get(ApiPaths.bucket_info_path(@bucket_id))
      @logger.debug { "Bucket info: #{result.inspect}" }
      result
    end

    # List buckets in a namespace (defaults to the current namespace).
    # @param namespace [String, nil] optional namespace override
    # @return [Array<Hash>] list of bucket entries
    def list_buckets(namespace: nil)
      ns = namespace || @bucket_id.split("/").first
      @logger.info("Listing buckets for namespace: #{ns}")
      @api.get_paginated(ApiPaths.buckets_path(ns))
    end

    # @return [Symbol] the current log level
    def log_level
      @logger.level
    end

    # @param level [Symbol] new log level
    def log_level=(level)
      @logger.level = level
    end

    # @return [Symbol] the current log format
    def log_format
      @logger.format
    end

    # @param format [Symbol] new log format
    def log_format=(format)
      @logger.format = format
    end

    # Closes all open connections and the logger.
    # @return [void]
    def close
      @api.close_all_connections
      @logger.close
    end
  end
end
