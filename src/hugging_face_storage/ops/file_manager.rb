# frozen_string_literal: true

module HuggingFaceStorage
  # File CRUD operations — upload, download, delete, move, copy, list, metadata, edit.
  class FileManager
    require_relative "lister"
    require_relative "metadata"
    require_relative "cross_copy"
    # Initializes a new FileManager.
    #
    # @param api_client [ApiClient] API client instance
    # @param xet_uploader [XetUploader] Xet uploader instance
    # @param xet_downloader [XetDownloader] Xet downloader instance
    # @param bucket_id [String] the bucket ID
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    def initialize(api_client:, xet_uploader:, xet_downloader:, bucket_id:,
                   upload_service:, delete_service:, copy_service:,
                   logger: nil, config: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @xet_downloader = xet_downloader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @file_editor = FileEditor.new(api_client: @api, xet_uploader: @xet_uploader, xet_downloader: @xet_downloader,
                                    bucket_id: @bucket_id, config: @config, logger: @logger)
      @upload_service = upload_service
      @delete_service = delete_service
      @copy_service = copy_service
      @lister = Lister.new(api_client: @api, bucket_id: @bucket_id, logger: @logger)
      @metadata = Metadata.new(api_client: @api, bucket_id: @bucket_id, logger: @logger)
      @cross_copy = CrossCopy.new(api_client: @api, bucket_id: @bucket_id, logger: @logger)
    end

    # Upload a local file to the bucket.
    #
    # +local_path+:: path to the local file
    # +remote_path+:: destination path in the bucket
    # +on_progress+:: called with +[uploaded_bytes, total_bytes]+
    # +cancel_token+:: cooperative cancellation
    # +exclude+:: glob pattern(s) to exclude
    #
    # @return [Hash{Symbol => String}] +{ path:, local_path: }+
    def upload(...)
      @upload_service.upload(...)
    end

    # Upload raw bytes to the bucket.
    #
    # +data+:: binary data to upload
    # +remote_path+:: destination path
    # +on_progress+:: progress callback
    # +cancel_token+:: cooperative cancellation
    #
    # @return [Hash{Symbol => String, Integer}] +{ path:, size: }+
    def upload_bytes(...)
      @upload_service.upload_bytes(...)
    end

    # Downloads a file to a local path or returns a lazy file handle.
    #
    # @param remote_path [String] remote file path
    # @param local_path [String, nil] local destination path (nil returns lazy handle)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [String, XetLazyFile] local path or lazy file handle
    def download(remote_path, local_path = nil, cancel_token: nil)
      ensure_file_exists!(remote_path)
      if local_path.nil?
        @logger.debug { "Lazy file handle: #{remote_path}" }
        return XetLazyFile.new(
          bucket_id: @bucket_id,
          remote_path: remote_path,
          api_client: @api,
          xet_downloader: @xet_downloader
        )
      end

      @logger.info("Downloading file: #{remote_path} -> #{local_path}")
      cancel_token&.raise_if_cancelled!
      @xet_downloader.download_file(@bucket_id, remote_path, local_path, cancel_token: cancel_token)
      @logger.info("Download complete: #{local_path}")
      local_path
    end

    # Returns a lazy file handle for remote file access without downloading.
    #
    # @param remote_path [String] remote file path
    # @return [XetLazyFile] lazy file handle
    def open(remote_path)
      XetLazyFile.new(
        bucket_id: @bucket_id,
        remote_path: remote_path,
        api_client: @api,
        xet_downloader: @xet_downloader
      )
    end

    # Deletes one or more files from the bucket in batches.
    #
    # +path+:: file path or array of paths
    # +cancel_token+:: cooperative cancellation token
    # +raise_on_partial_failure+:: raise if any deletion fails
    #
    # @return [Boolean, BatchResult] true for single file, BatchResult for multiple
    def delete(...)
      @delete_service.delete(...)
    end

    # Moves (copies then deletes) a file to a new path within the same bucket.
    #
    # @param source_path [String] current file path
    # @param destination_path [String] target file path
    # @param overwrite [Boolean] overwrite destination if it exists
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Boolean}] result with :from, :to, optionally :skipped
    def move(source_path, destination_path, overwrite: false, cancel_token: nil)
      @logger.info("Moving file: #{source_path} -> #{destination_path}")
      if !overwrite && exists?(destination_path)
        @logger.info("  Skipped (destination exists): #{destination_path}")
        return { from: source_path, to: destination_path, skipped: true }
      end
      file_info = fetch_info(source_path)
      copy_operations = [{
        type: ApiOperations::COPY_FILE,
        path: destination_path,
        xetHash: file_info[:xet_hash],
        sourceRepoType: "bucket",
        sourceRepoId: @bucket_id,
      }]
      delete_operations = [{ type: ApiOperations::DELETE_FILE, path: source_path }]

      cancel_token&.raise_if_cancelled!
      @api.batch(@bucket_id, copy_operations + delete_operations, cancel_token: cancel_token)
      @logger.info("Moved: #{source_path} -> #{destination_path}")
      { from: source_path, to: destination_path }
    end

    # Renames a file within the same bucket.
    #
    # @param old_path [String] current file path
    # @param new_path [String] new file path
    # @param overwrite [Boolean] overwrite destination if it exists
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Boolean}] result with :from, :to, optionally :skipped
    def rename(old_path, new_path, overwrite: false, cancel_token: nil)
      @logger.warn "[DEPRECATION] `rename` is deprecated — use `move` instead."
      move(old_path, new_path, overwrite: overwrite, cancel_token: cancel_token)
    end

    # Copies a file within the same bucket using server-side Xet copy.
    #
    # +source_path+:: source file path
    # +destination_path+:: destination file path
    # +overwrite+:: overwrite destination if it exists
    # +cancel_token+:: cooperative cancellation token
    #
    # @return [Hash{Symbol => String}] result with :from and :to
    def copy(...)
      @copy_service.copy(...)
    end

    # Copies files from an external repository (model, dataset, space, or bucket) into this bucket.
    #
    # +source_type+:: source repository type
    # +source_repo+:: source repository identifier
    # +files+:: array of file entries for batch copy
    # +source_path+:: source path for single file copy
    # +xet_hash+:: Xet hash for single file copy
    # +destination+:: destination path for single file copy
    # +overwrite+:: overwrite existing files
    # +cancel_token+:: cooperative cancellation token
    #
    # @return [Hash{Symbol => String, Integer}] result with :from and :to or :files_copied
    def copy_from(...)
      @copy_service.copy_from(...)
    end

    # Copies a single file from an external repository.
    #
    # +source_type+:: source repository type
    # +source_repo+:: source repository identifier
    # +source_path+:: source file path
    # +destination+:: destination path (appends basename if ends with "/")
    # +revision+:: source revision
    # +overwrite+:: overwrite existing files
    # +on_progress+:: progress callback
    # +cancel_token+:: cooperative cancellation token
    #
    # @return [Hash{Symbol => String}] result with :from and :to
    def copy_file(...)
      @copy_service.copy_file(...)
    end

    # Copies multiple files from external repositories using the copy pipeline.
    #
    # +files+:: array of file entries with source and destination info
    # +overwrite+:: overwrite existing files
    # +on_progress+:: progress callback
    # +cancel_token+:: cooperative cancellation token
    # +raise_on_partial_failure+:: raise if any copy fails
    #
    # @return [Hash{Symbol => Integer}] result with :xet_copied, :files_downloaded, :total, :skipped
    def copy_files(...)
      @copy_service.copy_files(...)
    end

    # Applies edits to a remote file.
    #
    # @param remote_path [String] remote file path
    # @param edits [Array<Hash>] edit operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Object] result from the file editor
    def edit(remote_path, edits:, cancel_token: nil)
      @file_editor.edit(remote_path, edits: edits, cancel_token: cancel_token)
    end

    # Lists files in the bucket, optionally filtered by prefix.
    #
    # +prefix+:: path prefix to filter by
    # +recursive+:: list recursively
    # +lazy+:: return a lazy enumerator instead of an array
    #
    # @return [Array<FileInfo>, Enumerator<FileInfo>] file info objects
    def list(...)
      @lister.list(...)
    end

    # Fetches metadata for a single file.
    # Lists both files and directories, optionally filtered by prefix.
    #
    # +prefix+:: path prefix to filter by
    # +recursive+:: list recursively
    #
    # @return [Array<EntryInfo>] entry info objects for both files and directories
    def list_entries(...)
      @lister.list_entries(...)
    end

    #
    # +path+:: file path
    #
    # @return [FileInfo] file metadata
    # @raise [NotFoundError] if the file is not found
    def metadata(...)
      @metadata.metadata(...)
    end

    # Checks whether a file exists in the bucket.
    #
    # +path+:: file path
    #
    # @return [Boolean] true if the file exists
    def exists?(...)
      @metadata.exists?(...)
    end

    private

    # Raises if the file at the given path does not exist in the bucket.
    #
    # @param path [String] remote file path
    # @return [void]
    def ensure_file_exists!(path)
      BucketQuery.ensure_file!(@api, @bucket_id, path)
    end

    # Raises if any of the given paths do not exist in the bucket.
    #
    # @param paths [Array<String>] remote file paths
    # @return [void]
    def ensure_files_exist!(paths)
      BucketQuery.ensure_files!(@api, @bucket_id, paths)
    end

    # Fetches file info (xet_hash, size) for the given path.
    #
    # @param path [String] remote file path
    # @return [Hash] file info hash
    def fetch_info(path)
      BucketQuery.fetch_file_info(@api, @bucket_id, path)
    end
  end
end
