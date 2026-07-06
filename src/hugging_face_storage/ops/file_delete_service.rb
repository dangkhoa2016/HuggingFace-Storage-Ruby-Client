# frozen_string_literal: true

module HuggingFaceStorage
  # Handles file deletion operations — single and batch delete.
  class FileDeleteService
    include Instrumentation

    # @param api_client [ApiClient] API client instance
    # @param bucket_id [String] the bucket identifier
    # @param config [Configuration] configuration object
    # @param logger [Logger, nil] logger instance
    def initialize(api_client:, bucket_id:, config:, logger: nil, metrics_registry: nil, notifications: nil)
      @api = api_client
      @bucket_id = bucket_id
      @config = config
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Deletes one or more files from the bucket in batches.
    #
    # @param path [String, Array<String>] file path or array of paths
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any deletion fails
    # @return [Boolean, BatchResult] true for single file, BatchResult for multiple
    def delete(path, cancel_token: nil, raise_on_partial_failure: true)
      paths = path.is_a?(Array) ? path.map { |p| Paths.strip_leading_slash(p) } : [Paths.strip_leading_slash(path)]
      ensure_files_exist!(paths)
      @logger.info("Deleting #{paths.size} file(s)")
      result = execute_delete_batches(paths, cancel_token, raise_on_partial_failure)
      @logger.info("Deleted #{paths.size} file(s)")
      @notifications.publish(:file_deleted, paths: paths)
      @metrics_registry.increment(:operations, paths.size)
      paths.one? && result.success? ? true : result
    end

    private

    # Raises if any of the given paths do not exist in the bucket.
    #
    # @param paths [Array<String>] remote file paths
    # @return [void]
    def ensure_files_exist!(paths)
      BucketQuery.ensure_files!(@api, @bucket_id, paths)
    end

    def execute_delete_batches(paths, cancel_token, raise_on_partial_failure)
      result = BatchResult.new
      paths.each_slice(@config.delete_batch_size) do |chunk|
        cancel_token&.raise_if_cancelled!
        partial = @api.batch(@bucket_id, chunk.map { |p| { type: ApiOperations::DELETE_FILE, path: p } },
                             cancel_token: cancel_token, raise_on_partial_failure: raise_on_partial_failure)
        result.merge!(partial)
      end
      result.raise_if_any! if raise_on_partial_failure && !result.success?
      result
    end
  end
end
