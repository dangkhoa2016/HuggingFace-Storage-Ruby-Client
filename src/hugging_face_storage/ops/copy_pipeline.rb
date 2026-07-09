# frozen_string_literal: true

module HuggingFaceStorage
  # Orchestrates copy operations between source repos and a destination bucket.
  class CopyPipeline
    include Instrumentation

    # Data object holding copy result counters.
    #
    # @!attribute [r] xet_copied
    #   @return [Integer] number of files copied via Xet
    # @!attribute [r] files_downloaded
    #   @return [Integer] number of files downloaded
    # @!attribute [r] total
    #   @return [Integer] total number of files processed
    # @!attribute [r] skipped
    #   @return [Integer] number of files skipped
    Result = Struct.new(:xet_copied, :files_downloaded, :total, :skipped)

    # Creates a new copy pipeline.
    #
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] the Xet uploader
    # @param bucket_id [String] the destination bucket ID
    # @param logger [Logger, nil] optional logger
    # @param config [Configuration, nil] optional configuration
    def initialize(api_client:, xet_uploader:, bucket_id:, logger: nil, config: nil,
                   metrics_registry: nil, notifications: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Runs the full copy pipeline for the given file list.
    #
    # @param files [Array<Hash>] the files to copy
    # @param overwrite [Boolean] overwrite existing files
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param raise_on_partial_failure [Boolean] raise on partial failure
    # @return [Result] the copy result
    def call(files:, overwrite: false, on_progress: nil, cancel_token: nil, raise_on_partial_failure: true)
      return Result.new(0, 0, 0, 0) if files.empty?

      entries = normalize_destinations(files)
      groups = group_by_source(entries)
      # @type var copy_ops: Array[Hash[Symbol, untyped]]
      copy_ops = []
      # @type var pending_downloads: Array[Hash[Symbol, untyped]]
      pending_downloads = []

      classify_groups(groups, copy_ops, pending_downloads, cancel_token: cancel_token)

      total_skipped = 0
      total_skipped += filter_existing(copy_ops, pending_downloads) unless overwrite

      xet_count = copy_ops.size
      download_count = pending_downloads.size

      execute_downloads(pending_downloads, copy_ops, cancel_token: cancel_token, on_progress: on_progress)
      execute_batch(copy_ops, cancel_token: cancel_token, raise_on_partial_failure: raise_on_partial_failure)

      result = Result.new(xet_count, download_count, xet_count + download_count, total_skipped)
      @notifications.publish(:batch_copy_completed, xet_copied: result.xet_copied,
                                                    files_downloaded: result.files_downloaded, total: result.total,
                                                    skipped: result.skipped)
      @metrics_registry.increment(:operations)
      result
    end

    # Executes pre-classified copy operations and pending downloads.
    #
    # @param copy_ops [Array<Hash>] the Xet copy operations
    # @param pending_downloads [Array<Hash>] files requiring download
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param raise_on_partial_failure [Boolean] raise on partial failure
    # @return [Hash] result with :xet_copied, :files_downloaded, :total, :elapsed_ms
    def execute(copy_ops:, pending_downloads:, cancel_token: nil, raise_on_partial_failure: true)
      op_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      xet_count = copy_ops.size
      download_count = pending_downloads.size

      execute_downloads(pending_downloads, copy_ops, cancel_token: cancel_token)
      execute_batch(copy_ops, cancel_token: cancel_token, raise_on_partial_failure: raise_on_partial_failure)

      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - op_t0) * 1000).round

      { xet_copied: xet_count, files_downloaded: download_count, total: xet_count + download_count,
        elapsed_ms: elapsed_ms }
    end

    private

    # Normalizes destination paths by resolving trailing slashes and collapsing duplicates.
    #
    # @param files [Array<Hash>] file entries with :destination and :source_path
    # @return [Array<Hash>] file entries with normalized :destination
    def normalize_destinations(files)
      files.map do |f|
        dest = f[:destination].end_with?("/") ? "#{f[:destination]}#{File.basename(f[:source_path])}" : f[:destination]
        dest = dest.gsub(%r{/{2,}}, "/")
        f.merge(destination: dest)
      end
    end

    # Groups file entries by source (source_type, source_repo, revision).
    #
    # @param files [Array<Hash>] file entries with :source_type, :source_repo, :revision
    # @return [Hash<String, Hash>] grouped entries keyed by source
    def group_by_source(files)
      # @type var groups: Hash[String, Hash[Symbol, untyped]]
      groups = {}
      files.each do |f|
        rev = f[:revision]
        key = "#{f[:source_type]}\0#{f[:source_repo]}\0#{rev}"
        # @type var entries: Array[Hash[Symbol, untyped]]
        entries = []
        default = { source_type: f[:source_type], source_repo: f[:source_repo], revision: rev,
                    entries: entries }
        (groups[key] ||= default)[:entries] << { source_path: f[:source_path], destination: f[:destination] }
      end
      groups
    end

    # Classifies each group into Xet copy operations or pending downloads via EntryClassifier.
    #
    # @param groups [Hash<String, Hash>] grouped source entries
    # @param copy_ops [Array<Hash>] output array for Xet copy operations
    # @param pending_downloads [Array<Hash>] output array for files requiring download
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [void]
    def classify_groups(groups, copy_ops, pending_downloads, cancel_token: nil)
      groups.each_value do |group|
        cancel_token&.raise_if_cancelled!
        effective_revision = group[:source_type] == "bucket" ? nil : (group[:revision] || "main")
        path_infos = fetch_path_infos(group, effective_revision, cancel_token)

        classified = EntryClassifier.classify(
          group[:entries],
          source_type: group[:source_type],
          source_repo: group[:source_repo],
          revision: effective_revision,
          debug_mode: @config.debug_mode,
          path_infos: path_infos,
          destination_mapper: ->(entry) { entry[:destination] }
        )

        LfsGuard.new("#{group[:source_type]}:#{group[:source_repo]}").check(classified[:lfs_offenders])
        copy_ops.concat(classified[:copy_ops])
        pending_downloads.concat(classified[:pending_downloads])
      end
    end

    # Removes files that already exist in the destination bucket.
    #
    # @param copy_ops [Array<Hash>] Xet copy operations to filter
    # @param pending_downloads [Array<Hash>] pending downloads to filter
    # @return [Integer] number of files skipped
    def filter_existing(copy_ops, pending_downloads)
      skipped = 0
      skipped += BucketQuery.reject_existing!(@api, @bucket_id, copy_ops, path_key: :path)
      skipped += BucketQuery.reject_existing!(@api, @bucket_id, pending_downloads, path_key: :destination)
      @logger.info("  Skipped #{skipped} existing file(s)") if skipped.positive?
      skipped
    end

    module ExecutionHelpers
      def fetch_path_infos(group, effective_revision, cancel_token)
        paths = group[:entries].map { |e| e[:source_path] }
        if group[:source_type] == "bucket"
          @api.post(ApiPaths.paths_info_path(group[:source_repo]),
                    body: { paths: paths }, cancel_token: cancel_token)
        else
          @api.post(
            "#{ApiPaths.repo_paths_info_path(group[:source_type], group[:source_repo])}/#{effective_revision}",
            body: { paths: paths }, cancel_token: cancel_token
          )
        end
      end

      def execute_downloads(pending_downloads, copy_ops, cancel_token: nil, on_progress: nil)
        return unless pending_downloads.any?

        total_downloads = pending_downloads.size
        downloaded_count = 0

        copier = RepoFileCopier.new(
          api_client: @api, xet_uploader: @xet_uploader, bucket_id: @bucket_id, logger: @logger,
          config: @config
        )
        copier.copy(pending_downloads,
                    cancel_token: cancel_token,
                    on_progress: lambda { |progress|
                      downloaded_count = progress[:downloaded]
                      on_progress&.call(path: progress[:path], downloaded: downloaded_count, total: total_downloads)
                    },
                    on_large_complete: ->(op) { copy_ops << op })
      end

      def execute_batch(copy_ops, cancel_token: nil, raise_on_partial_failure: true)
        return unless copy_ops.any?

        copy_ops.each_slice(@config.copy_batch_size) do |chunk|
          cancel_token&.raise_if_cancelled!
          @api.batch(@bucket_id, chunk, cancel_token: cancel_token,
                                        raise_on_partial_failure: raise_on_partial_failure)
        end
      end
    end

    include ExecutionHelpers
  end
end
