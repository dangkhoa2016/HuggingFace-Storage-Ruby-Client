# frozen_string_literal: true

module HuggingFaceStorage
  # Copies files/directories within the same bucket.
  class SameBucketCopyService
    include Instrumentation

    # @param api_client [ApiClient] the API client
    # @param file_manager [FileManager, nil] file listing interface (required for directory copy)
    # @param bucket_id [String] bucket identifier
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration
    # @param copy_pipeline [CopyPipeline, nil] pipeline to execute copy operations
    def initialize(api_client:, bucket_id:, file_manager: nil, logger: nil, config: nil, copy_pipeline: nil,
                   metrics_registry: nil, notifications: nil)
      @api = api_client
      @files = file_manager
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @copy_pipeline = copy_pipeline
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Copies one or more source paths to a destination within the same bucket.
    #
    # @param source_path [String, Array<String>] source path(s)
    # @param destination_path [String] destination path
    # @param overwrite [Boolean] overwrite existing files (default false)
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash, Array] single result hash or array of results for multiple sources
    def copy(source_path, destination_path, overwrite: false, cancel_token: nil)
      sources = Array(source_path)
      normalized_dst_base = Paths.normalize(destination_path)
      # @type var all_results: Array[Hash[Symbol, untyped]]
      all_results = []
      total_copied = 0

      sources.each do |src|
        cancel_token&.raise_if_cancelled!
        normalized_src, dst = normalize_paths(src, normalized_dst_base)
        dst = "#{dst}/#{File.basename(normalized_src)}" if sources.size > 1
        result = execute_same_bucket_copy(normalized_src, dst, overwrite, cancel_token)
        total_copied += result[:files_copied]
        all_results << { from: src, to: dst, files_copied: result[:files_copied], skipped: result[:skipped] }
      end

      sources.one? ? all_results.first : { directories: all_results, total_files_copied: total_copied }
    end

    # Normalizes source and destination paths.
    #
    # @param source_path [String] source path
    # @param destination_path [String] destination path
    # @return [Array(String, String)] normalized [source, destination]
    def normalize_paths(source_path, destination_path)
      normalized_src = Paths.normalize(source_path)
      normalized_dst = Paths.normalize(destination_path)
      [normalized_src, normalized_dst]
    end

    # Executes a same-bucket copy by building operations and running the pipeline.
    #
    # @param source_path [String] normalized source path
    # @param destination_path [String] normalized destination path
    # @param overwrite [Boolean] overwrite existing files
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] result with :files_copied and :skipped
    def execute_same_bucket_copy(source_path, destination_path, overwrite, cancel_token)
      @logger.info("Copying directory: #{source_path} -> #{destination_path}")
      copy_ops, skipped, file_count = build_copy_operations(source_path, destination_path, overwrite)

      if skipped.positive?
        @logger.info("  Skipped #{skipped}/#{file_count} file(s) already exist at destination")
        if copy_ops.empty?
          @logger.info(
            "  Nothing to copy - all #{file_count} source file(s) already exist at '#{destination_path}'"
          )
        end
      end

      if copy_ops.any?
        # @type var pending: Array[Hash[Symbol, untyped]]
        pending = []
        @copy_pipeline.execute(copy_ops: copy_ops, pending_downloads: pending, cancel_token: cancel_token)
        @logger.info("Copied #{copy_ops.size} file(s): #{source_path} -> #{destination_path}")
      end

      { files_copied: copy_ops.size, skipped: skipped }
    end

    def build_copy_operations(source_path, destination_path, overwrite)
      files = @files.list(prefix: source_path, recursive: true)
      raise NotFoundError, "No files found in directory: #{source_path}" if files.empty?

      items = build_copy_items(files, source_path, destination_path)
      skipped = BucketQuery.reject_existing!(@api, @bucket_id, items, path_key: :path) unless overwrite
      copy_ops = build_copy_ops_from_items(items)

      [copy_ops, skipped || 0, files.size]
    end

    def build_copy_items(files, source_path, destination_path)
      files.map do |file_info|
        relative = file_info.path.sub(%r{^#{Regexp.escape(source_path)}/?}, "")
        { file_info: file_info, path: "#{destination_path}/#{relative}" }
      end
    end

    def build_copy_ops_from_items(items)
      all_paths = items.map { |item| item[:file_info].path }
      path_infos = BucketQuery.query_paths(@api, @bucket_id, all_paths) || []
      info_map = path_infos.to_h { |r| [r[ResponseFields::PATH], r] }

      items.map do |item|
        info = info_map[item[:file_info].path] || {}
        {
          type: ApiOperations::COPY_FILE,
          path: item[:path],
          xetHash: info[ResponseFields::XET_HASH],
          sourceRepoType: "bucket",
          sourceRepoId: @bucket_id,
        }
      end
    end

    # Copies a single file within the same bucket using server-side Xet copy.
    #
    # @param source_path [String] source file path
    # @param destination_path [String] destination file path
    # @param overwrite [Boolean] overwrite destination if it exists
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String}] result with :from and :to
    def copy_file(source_path, destination_path, overwrite: false, cancel_token: nil)
      @logger.info("Copying file: #{source_path} -> #{destination_path}")
      return { from: source_path, to: destination_path } unless overwrite || !@api.file_exists?(@bucket_id,
                                                                                                destination_path)

      file_info = BucketQuery.fetch_file_info(@api, @bucket_id, source_path)

      cancel_token&.raise_if_cancelled!
      @api.batch(@bucket_id, [{
        type: ApiOperations::COPY_FILE,
        path: destination_path,
        xetHash: file_info[:xet_hash],
        sourceRepoType: "bucket",
        sourceRepoId: @bucket_id,
      }], cancel_token: cancel_token)

      @logger.info("Copied: #{source_path} -> #{destination_path}")
      { from: source_path, to: destination_path }
    end
  end
end
