# frozen_string_literal: true

module HuggingFaceStorage
  # Orchestrates cross-repository file copy operations.
  class CrossRepoCopyService
    include Instrumentation

    # Creates a new cross-repo copy service.
    #
    # @param api_client [ApiClient] the API client
    # @param file_manager [FileManager] the file manager
    # @param copy_pipeline [CopyPipeline] the copy pipeline
    # @param bucket_id [String] the destination bucket ID
    # @param source_iterator [SourceIterator] the source iterator
    # @param logger [Logger, nil] optional logger
    def initialize(api_client:, file_manager:, copy_pipeline:, bucket_id:, source_iterator:, logger: nil,
                   metrics_registry: nil, notifications: nil)
      @api = api_client
      @files = file_manager
      @copy_pipeline = copy_pipeline
      @bucket_id = bucket_id
      @source_iterator = source_iterator
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
      @tree_copy = TreeCopyStrategy.new(api_client: @api, file_manager: @files, bucket_id: @bucket_id, logger: @logger)
      @repo_copy = RepoCopyStrategy.new(api_client: @api, source_iterator: @source_iterator, logger: @logger)
      @folder_copy = FolderCopyStrategy.new(api_client: @api, source_iterator: @source_iterator, logger: @logger)
      @batch_plan_executor = BatchPlanExecutor.new(api_client: @api, source_iterator: @source_iterator,
                                                   copy_pipeline: @copy_pipeline, bucket_id: @bucket_id,
                                                   logger: @logger)
    end

    # Copies files from a tree listing into the destination bucket.
    #
    # +source_type+:: source type
    # +source_repo+:: source repository name
    # +tree+:: tree file entries
    # +source_prefix+:: optional source path prefix filter
    # +destination_prefix+:: optional destination prefix
    # +exclude+:: glob patterns to exclude
    # +overwrite+:: overwrite existing files
    # +cancel_token+:: optional cancellation token
    #
    # @return [Hash] result with :files_copied, :skipped, :total_size, :source
    def copy_from_tree(...)
      raise ArgumentError, "file_manager is required for copy_from_tree" unless @files

      @tree_copy.call(...)
    end

    # Copies files from a source repo into the destination bucket.
    #
    # @param source_type [String] source type ("model", "dataset", or "bucket")
    # @param source_repo [String] source repository name
    # @param source_path [String, nil] optional sub-path within the source
    # @param destination_prefix [String, nil] optional destination prefix
    # @param revision [String] revision (branch, tag, or commit)
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param overwrite [Boolean] overwrite existing files
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash, Array<Hash>] result with :files_copied, :total, :skipped, etc.
    def copy_from_repo(source_type:, source_repo:, source_path: nil, destination_prefix: nil, revision: "main",
                       exclude: nil, overwrite: false, cancel_token: nil)
      normalized_dst_base = destination_prefix ? Paths.normalize(destination_prefix) : nil
      sources = source_path ? Array(source_path) : [nil]

      result = @repo_copy.call(
        sources: sources, normalized_dst_base: normalized_dst_base,
        source_type: source_type, source_repo: source_repo, revision: revision,
        exclude: exclude, cancel_token: cancel_token
      )

      plan_result = execute_batch_plan(result[:copy_ops], result[:pending_downloads], result[:results],
                                       overwrite: overwrite, cancel_token: cancel_token, label: "Cross-repo copy")

      merged = {
        files_copied: plan_result[:xet_copied],
        files_downloaded: plan_result[:files_downloaded],
        total: plan_result[:total],
        skipped: plan_result[:skipped_files],
        skipped_directories: plan_result[:skipped_dirs],
        source: "#{source_type}:#{source_repo}",
      }

      all_results = result[:results]
      all_results.one? ? all_results.first.merge(merged) : { directories: all_results }.merge(merged)
    end

    # Copies multiple source folders to the destination bucket.
    #
    # @param folders [Array<Hash>] list of folder copy specifications
    # @param overwrite [Boolean] overwrite existing files
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param raise_on_partial_failure [Boolean] raise on partial failure
    # @return [Hash] result with :folders, :xet_copied, :files_downloaded, :total, :skipped
    def copy_folders(folders:, overwrite: false, on_progress: nil, cancel_token: nil, raise_on_partial_failure: true) # rubocop:disable Lint/UnusedMethodArgument
      return { folders_copied: 0, files_downloaded: 0, skipped: 0 } if folders.empty?

      folder_result = @folder_copy.call(folders: folders, cancel_token: cancel_token)

      plan_result = @batch_plan_executor.call(
        copy_ops: folder_result[:copy_ops],
        pending_downloads: folder_result[:pending_downloads],
        source_results: folder_result[:results],
        overwrite: overwrite, cancel_token: cancel_token, label: "Copy folders",
        raise_on_partial_failure: raise_on_partial_failure
      )

      {
        folders: folder_result[:results],
        xet_copied: plan_result[:xet_copied],
        files_downloaded: plan_result[:files_downloaded],
        total: plan_result[:total],
        skipped: plan_result[:skipped_files],
        skipped_directories: plan_result[:skipped_dirs],
      }
    end

    module CopyOperations
      # Copies a single file identified by xet_hash from a source repo to the destination bucket.
      #
      # @param source_type [String] source repository type
      # @param source_repo [String] source repository identifier
      # @param xet_hash [String] Xet hash of the file to copy
      # @param destination [String] destination path
      # @param source_path [String, nil] original source path (for logging)
      # @param overwrite [Boolean] overwrite existing files
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Hash{Symbol => String}] result with :from and :to
      def single_copy(source_type:, source_repo:, xet_hash:, destination:, source_path: nil,
                      overwrite: false, cancel_token: nil)
        @logger.info("Cross-copy: #{source_type}:#{source_repo}/#{source_path || xet_hash[0..7]} -> #{destination}")
        return { from: "#{source_type}:#{source_repo}", to: destination } unless overwrite || !@api.file_exists?(
          @bucket_id, destination
        )

        cancel_token&.raise_if_cancelled!
        @api.batch(@bucket_id, [{
          type: ApiOperations::COPY_FILE,
          path: destination,
          xetHash: xet_hash,
          sourceRepoType: source_type,
          sourceRepoId: source_repo,
        }], cancel_token: cancel_token)
        @logger.info("Cross-copy complete: #{destination}")
        { from: "#{source_type}:#{source_repo}", to: destination }
      end

      # Copies a batch of files from a source repo to the destination bucket.
      #
      # @param source_type [String] source repository type
      # @param source_repo [String] source repository identifier
      # @param files [Array<Hash>] array of file entries with :xet_hash and :destination
      # @param overwrite [Boolean] overwrite existing files
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Hash{Symbol => String, Integer}] result with :from and :files_copied
      def batch_copy(source_type:, source_repo:, files:, overwrite: false, cancel_token: nil)
        unless overwrite
          skipped = BucketQuery.reject_existing!(@api, @bucket_id, files, path_key: :destination)
          @logger.info("  Skipped #{skipped} existing file(s)") if skipped.positive?
        end

        return { from: "#{source_type}:#{source_repo}", files_copied: 0 } if files.empty?

        @logger.info("Batch cross-copy: #{files.size} file(s) from #{source_type}:#{source_repo}")
        operations = files.map do |f|
          {
            type: ApiOperations::COPY_FILE,
            path: f[:destination],
            xetHash: f[:xet_hash],
            sourceRepoType: source_type,
            sourceRepoId: source_repo,
          }
        end

        cancel_token&.raise_if_cancelled!
        @api.batch(@bucket_id, operations, cancel_token: cancel_token)
        @logger.info("Batch cross-copy complete: #{files.size} file(s)")
        { from: "#{source_type}:#{source_repo}", files_copied: files.size }
      end

      def execute_batch_plan(copy_ops, pending_downloads, source_results, overwrite:, cancel_token:, label:,
                             raise_on_partial_failure: true)
        @batch_plan_executor.call(
          copy_ops: copy_ops, pending_downloads: pending_downloads,
          source_results: source_results, overwrite: overwrite,
          cancel_token: cancel_token, label: label,
          raise_on_partial_failure: raise_on_partial_failure
        )
      end
    end

    include CopyOperations
  end
end

require_relative "tree_copy_strategy"
require_relative "repo_copy_strategy"
require_relative "folder_copy_strategy"
require_relative "batch_plan_executor"
