# frozen_string_literal: true

module HuggingFaceStorage
  # Handles directory copy operations: same-bucket, cross-repo, tree-based, and batch folder copy.
  class DirectoryCopyService
    include Instrumentation

    # Initializes a new DirectoryCopyService.
    #
    # @param same_bucket_copy [SameBucketCopyService] same-bucket copy service
    # @param cross_repo_copy [CrossRepoCopyService] cross-repo copy service
    # @param copy_pipeline [CopyPipeline] copy pipeline for execution
    # @param config [Configuration, nil] configuration object
    # @param logger [Logger, nil] logger instance
    # @param metrics_registry [MetricsRegistry, nil] metrics registry
    # @param notifications [Notifications::Channel, nil] notifications channel
    def initialize(same_bucket_copy:, cross_repo_copy:, copy_pipeline:, config: nil, logger: nil,
                   metrics_registry: nil, notifications: nil)
      @same_bucket_copy = same_bucket_copy
      @cross_repo_copy = cross_repo_copy
      @copy_pipeline = copy_pipeline
      @config = config || Configuration.default
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Copies files from a tree listing into the destination bucket.
    #
    # @param source_type [String] source repository type
    # @param source_repo [String] source repository identifier
    # @param tree [Array<Hash>, String] tree entries or JSON file path
    # @param source_prefix [String, nil] optional source path prefix filter
    # @param destination_prefix [String, nil] optional destination prefix
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash{Symbol => String, Integer}] copy result
    def copy_from_tree(source_type:, source_repo:, tree:, source_prefix: nil, destination_prefix: nil, exclude: nil,
                       overwrite: false, cancel_token: nil)
      @cross_repo_copy.copy_from_tree(
        source_type: source_type, source_repo: source_repo, tree: tree,
        source_prefix: source_prefix, destination_prefix: destination_prefix,
        exclude: exclude, overwrite: overwrite, cancel_token: cancel_token
      )
    end

    # Copies files from a source repository into the destination bucket.
    #
    # @param source_type [String] source repository type
    # @param source_repo [String] source repository identifier
    # @param source_path [String, nil] optional sub-path within the source
    # @param destination_prefix [String, nil] optional destination prefix
    # @param revision [String] revision (branch, tag, or commit) (default "main")
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash, Array<Hash>] copy result
    def copy_from_repo(source_type:, source_repo:, source_path: nil, destination_prefix: nil, revision: "main",
                       exclude: nil, overwrite: false, cancel_token: nil)
      @cross_repo_copy.copy_from_repo(
        source_type: source_type, source_repo: source_repo,
        source_path: source_path, destination_prefix: destination_prefix,
        revision: revision, exclude: exclude, overwrite: overwrite,
        cancel_token: cancel_token
      )
    end

    # Copies files/directories, dispatching to cross-repo or same-bucket copy.
    #
    # @param source_path [String] source path
    # @param destination_path [String] destination path
    # @param source_type [String, nil] source type (required for cross-repo)
    # @param source_repo [String, nil] source repo (required for cross-repo)
    # @param revision [String] revision (default "main")
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @return [Hash, Array] copy result
    def copy(source_path, destination_path, source_type: nil, source_repo: nil, revision: "main", exclude: nil,
             overwrite: false)
      if source_type && source_repo
        @cross_repo_copy.copy_from_repo(
          source_type: source_type, source_repo: source_repo,
          source_path: source_path, destination_prefix: destination_path,
          revision: revision, exclude: exclude, overwrite: overwrite
        )
      else
        @same_bucket_copy.copy(source_path, destination_path, overwrite: overwrite)
      end
    end

    # Copies multiple source folders to the destination bucket.
    #
    # @param folders [Array<Hash>] list of folder copy specifications
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param raise_on_partial_failure [Boolean] raise on partial failure (default true)
    # @return [Hash{Symbol => Integer}] folder copy result
    def copy_folders(folders:, overwrite: false, on_progress: nil, cancel_token: nil, raise_on_partial_failure: true)
      @cross_repo_copy.copy_folders(
        folders: folders, overwrite: overwrite, on_progress: on_progress,
        cancel_token: cancel_token, raise_on_partial_failure: raise_on_partial_failure
      )
    end
  end
end
