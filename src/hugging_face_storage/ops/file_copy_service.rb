# frozen_string_literal: true

module HuggingFaceStorage
  # Delegation facade that dispatches copy operations to specialized services.
  class FileCopyService
    include Instrumentation

    # @param same_bucket [SameBucketCopyService] same-bucket single-file copy
    # @param cross_repo [CrossRepoCopyService] cross-repo file copy (batch + single)
    # @param copy_pipeline [CopyPipeline] multi-file copy pipeline
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    def initialize(same_bucket:, cross_repo:, copy_pipeline:, logger: nil, config: nil,
                   metrics_registry: nil, notifications: nil)
      @same_bucket = same_bucket
      @cross_repo = cross_repo
      @copy_pipeline = copy_pipeline
      @config = config || Configuration.default
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Copies a file within the same bucket using server-side Xet copy.
    #
    # @param source_path [String] source file path
    # @param destination_path [String] destination file path
    # @param overwrite [Boolean] overwrite destination if it exists (default false)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String}] result with :from and :to
    def copy(source_path, destination_path, overwrite: false, cancel_token: nil)
      result = @same_bucket.copy_file(source_path, destination_path, overwrite: overwrite, cancel_token: cancel_token)
      @notifications.publish(:file_copied, from: source_path, to: destination_path)
      @metrics_registry.increment(:operations)
      result
    end

    # Copies files from an external repository (model, dataset, space, or bucket).
    #
    # @param source_type [String] source repository type
    # @param source_repo [String] source repository identifier
    # @param files [Array<Hash>, nil] array of file entries for batch copy
    # @param source_path [String, nil] source path for single file copy
    # @param xet_hash [String, nil] Xet hash for single file copy
    # @param destination [String, nil] destination path for single file copy
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :from and :to or :files_copied
    def copy_from(source_type:, source_repo:, files: nil, source_path: nil, xet_hash: nil, destination: nil,
                  overwrite: false, cancel_token: nil)
      if files
        result = @cross_repo.batch_copy(source_type: source_type, source_repo: source_repo, files: files,
                                        overwrite: overwrite, cancel_token: cancel_token)
        @notifications.publish(:file_copied, source_type: source_type, source_repo: source_repo,
                                             files_copied: result[:files_copied])
      else
        raise ArgumentError, "xet_hash and destination are required for single file copy" unless xet_hash && destination

        result = @cross_repo.single_copy(source_type: source_type, source_repo: source_repo,
                                         xet_hash: xet_hash, destination: destination,
                                         source_path: source_path, overwrite: overwrite,
                                         cancel_token: cancel_token)
        @notifications.publish(:file_copied, from: result[:from], to: result[:to])
      end
      @metrics_registry.increment(:operations)
      result
    end

    # Copies a single file from an external repository into this bucket.
    #
    # @param source_type [String] source repository type
    # @param source_repo [String] source repository identifier
    # @param source_path [String] source file path
    # @param destination [String] destination path (appends basename if ends with "/")
    # @param revision [String] source revision (default "main")
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String}] result with :from and :to
    def copy_file(source_type:, source_repo:, source_path:, destination:, revision: "main", overwrite: false,
                  on_progress: nil, cancel_token: nil)
      dest = destination.end_with?("/") ? "#{destination}#{File.basename(source_path)}" : destination
      dest = dest.gsub(%r{/{2,}}, "/")
      files = [{
        source_type: source_type,
        source_repo: source_repo,
        source_path: source_path,
        destination: dest,
        revision: revision,
      }]
      @copy_pipeline.call(files: files, overwrite: overwrite,
                          on_progress: on_progress, cancel_token: cancel_token)
      @notifications.publish(:file_copied, from: "#{source_type}:#{source_repo}/#{source_path}", to: dest)
      @metrics_registry.increment(:operations)
      { from: "#{source_type}:#{source_repo}/#{source_path}", to: dest }
    end

    # Copies multiple files from external repositories using the copy pipeline.
    #
    # @param files [Array<Hash>] array of file entries with source and destination info
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any copy fails (default true)
    # @return [Hash{Symbol => Integer}] result with :xet_copied, :files_downloaded, :total, :skipped
    def copy_files(files:, overwrite: false, on_progress: nil, cancel_token: nil, raise_on_partial_failure: true)
      result = @copy_pipeline.call(
        files: files, overwrite: overwrite,
        on_progress: on_progress, cancel_token: cancel_token,
        raise_on_partial_failure: raise_on_partial_failure
      )
      @notifications.publish(:file_copied, total: result.total, xet_copied: result.xet_copied,
                                           files_downloaded: result.files_downloaded, skipped: result.skipped)
      @metrics_registry.increment(:operations)
      {
        xet_copied: result.xet_copied,
        files_downloaded: result.files_downloaded,
        total: result.total,
        skipped: result.skipped,
      }
    end
  end
end
