# frozen_string_literal: true

module HuggingFaceStorage
  # Handles directory CRUD operations: create, delete, exists?, list, list_files, metadata, move, rename.
  class DirectoryCrudService
    include Instrumentation

    # Initializes a new DirectoryCrudService.
    #
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] xet uploader for placeholder files
    # @param file_manager [FileManager] file listing interface
    # @param bucket_id [String] the bucket identifier
    # @param config [Configuration, nil] configuration object
    # @param logger [Logger, nil] logger instance
    # @param metrics_registry [MetricsRegistry, nil] metrics registry
    # @param notifications [Notifications::Channel, nil] notifications channel
    def initialize(api_client:, xet_uploader:, file_manager:, bucket_id:, config: nil, logger: nil,
                   metrics_registry: nil, notifications: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @files = file_manager
      @bucket_id = bucket_id
      @config = config || Configuration.default
      @logger = logger || NullLogger.new
      @metadata_cache = MetadataCache.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Creates a directory by uploading an empty placeholder file.
    #
    # @param path [String] directory path to create
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Boolean] true on success
    def create_directory(path, cancel_token: nil)
      normalized = Paths.normalize(path)
      @logger.info("Creating directory: #{normalized}")
      return true if exists?(normalized)

      placeholder = normalized.end_with?("/") ? normalized : "#{normalized}/"
      cancel_token&.raise_if_cancelled!
      @xet_uploader.upload_bytes_to_path(@bucket_id, "".b, placeholder, cancel_token: cancel_token)
      @logger.info("Directory created: #{normalized}")
      @notifications.publish(:directory_created, path: normalized)
      @metrics_registry.increment(:operations)

      true
    end

    # Deletes one or more directories and their contents.
    #
    # @param path [String, Array<String>] directory path or array of paths
    # @param recursive [Boolean] delete contents recursively (default true)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any deletion fails (default true)
    # @return [Boolean, BatchResult] true for single path, BatchResult for multiple
    def delete(path, recursive: true, cancel_token: nil, raise_on_partial_failure: true)
      paths = Array(path)
      all_ops = collect_delete_operations(paths, recursive, cancel_token)
      result = execute_batch_operations(all_ops, cancel_token, raise_on_partial_failure)
      @notifications.publish(:directory_deleted, paths: paths)
      @metrics_registry.increment(:operations)
      paths.one? && result.success? ? true : result
    end

    # Checks whether a directory exists.
    #
    # @param path [String] directory path
    # @return [Boolean] true if the directory exists
    def exists?(path)
      @logger.debug { "Checking directory existence: #{path}" }
      normalized = Paths.normalize(path)
      @api.head(ApiPaths.tree_path(@bucket_id, normalized))
      true
    rescue NotFoundError
      placeholder_exists?(Paths.normalize(path))
    end

    # Lists directories, optionally filtered by prefix.
    #
    # @param prefix [String, nil] optional path prefix
    # @return [Array<DirInfo>] list of directory info objects
    def list(prefix: nil)
      @logger.info("Listing directories: prefix=#{prefix || 'root'}")
      path = ApiPaths.tree_path(@bucket_id)
      path += "/#{prefix}" if prefix

      entries = @api.get_paginated(path, params: { recursive: "false" })
      dirs = entries.select { |e| e[ResponseFields::TYPE] == ResponseFields::DIR_TYPE }.map do |e|
        DirInfo.new(
          path: e[ResponseFields::PATH],
          uploaded_at: e["uploadedAt"]
        )
      end
      @logger.info("Found #{dirs.size} directory(ies)")
      dirs
    end

    # Lists files within a directory.
    #
    # @param path [String] directory path
    # @param recursive [Boolean] list recursively (default false)
    # @return [Array<FileInfo>] list of file info objects
    def list_files(path, recursive: false)
      @logger.debug { "Listing files in directory: #{path} recursive=#{recursive}" }
      normalized = Paths.normalize(path)
      @files.list(prefix: normalized, recursive: recursive)
    end

    # Fetches metadata for a directory (file count, total size).
    #
    # @param path [String] directory path
    # @return [DirInfo] directory metadata
    def metadata(path)
      @logger.info("Fetching directory metadata: #{path}")
      normalized = Paths.normalize(path)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      cached = @metadata_cache.fetch(normalized, nil)
      if cached && (now - cached[:timestamp]) < @config.metadata_cache_ttl
        @logger.debug { "Dir metadata (cached): #{cached[:info].inspect}" }
        return cached[:info]
      end

      files = list_files(normalized, recursive: true)
      total_size = files.sum(&:size)
      info = DirInfo.new(
        path: normalized,
        file_count: files.size,
        total_size: total_size
      )

      @metadata_cache.store(normalized, { info: info, timestamp: now })
      info
    end

    # Moves a directory by copying all files then deleting the originals.
    #
    # @param source_path [String] current directory path
    # @param destination_path [String] target directory path
    # @return [Hash{Symbol => String, Integer}] result with :from, :to, :files_moved
    def move(source_path, destination_path)
      @logger.info("Moving directory: #{source_path} -> #{destination_path}")
      normalized_src = Paths.normalize(source_path)
      normalized_dst = Paths.normalize(destination_path)
      files = list_files(normalized_src, recursive: true)

      raise NotFoundError, "No files found in directory: #{source_path}" if files.empty?

      copy_ops, delete_ops = build_move_operations(files, normalized_src, normalized_dst)
      @api.batch(@bucket_id, copy_ops + delete_ops)
      @logger.info("Moved #{files.size} file(s): #{source_path} -> #{destination_path}")
      { from: source_path, to: destination_path, files_moved: files.size }
    end

    # Renames a directory. Deprecated — use {#move} instead.
    #
    # @param old_path [String] current directory path
    # @param new_path [String] target directory path
    # @return [Hash{Symbol => String, Integer}] result from move
    # @deprecated Use {#move} instead.
    def rename(old_path, new_path)
      @logger.warn "[DEPRECATION] `rename` is deprecated — use `move` instead."
      move(old_path, new_path)
    end

    module CrudHelpers
      private

      def collect_delete_operations(paths, recursive, cancel_token)
        all_ops = []

        paths.each do |p|
          cancel_token&.raise_if_cancelled!
          normalized = Paths.normalize(p)
          @logger.info("Deleting directory: #{normalized} (recursive=#{recursive})")
          files = list_files(normalized, recursive: recursive)
          placeholder = "#{normalized}/"

          if files.empty?
            all_ops << { type: ApiOperations::DELETE_FILE, path: placeholder }
            next
          end

          raise Error, "Directory '#{p}' is not empty." unless recursive

          files.each { |f| all_ops << { type: ApiOperations::DELETE_FILE, path: f.path } }
          all_ops << { type: ApiOperations::DELETE_FILE, path: placeholder }
        end

        all_ops
      end

      def execute_batch_operations(all_ops, cancel_token, raise_on_partial_failure)
        result = BatchResult.new
        all_ops.each_slice(@config.delete_batch_size) do |chunk|
          cancel_token&.raise_if_cancelled!
          partial = @api.batch(@bucket_id, chunk, cancel_token: cancel_token,
                                                  raise_on_partial_failure: raise_on_partial_failure)
          result.merge!(partial)
        end
        result.raise_if_any! if raise_on_partial_failure && !result.success?
        result
      end

      def build_move_operations(files, normalized_src, normalized_dst)
        all_paths = files.map(&:path)
        path_infos = BucketQuery.query_paths(@api, @bucket_id, all_paths) || []
        info_map = path_infos.to_h { |r| [r[ResponseFields::PATH], r] }

        copy_ops = []
        delete_ops = []

        files.each do |file_info|
          relative = file_info.path.sub(%r{^#{Regexp.escape(normalized_src)}/?}, "")
          new_path = "#{normalized_dst}/#{relative}"
          info = info_map[file_info.path]
          raise NotFoundError, "File not found: #{file_info.path}" unless info

          copy_ops << {
            type: ApiOperations::COPY_FILE,
            path: new_path,
            xetHash: info[ResponseFields::XET_HASH],
            sourceRepoType: "bucket",
            sourceRepoId: @bucket_id,
          }
          delete_ops << { type: ApiOperations::DELETE_FILE, path: file_info.path }
        end

        [copy_ops, delete_ops]
      end

      def placeholder_exists?(normalized)
        results = BucketQuery.query_paths(@api, @bucket_id, [normalized])
        results&.any? || false
      rescue NotFoundError
        false
      end
    end

    include CrudHelpers
  end
end
