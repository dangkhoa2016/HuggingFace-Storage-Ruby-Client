# frozen_string_literal: true

module HuggingFaceStorage
  # Manages directory-level operations: create, delete, list, download, upload, copy, move.
  # Facade that delegates to specialized service objects.
  class DirectoryManager
    def initialize(api_client:, xet_uploader:, xet_downloader:, bucket_id:, file_manager:,
                   crud_service:, transfer_service:, copy_service:,
                   logger: nil, config: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @xet_downloader = xet_downloader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @files = file_manager
      @crud_service = crud_service
      @transfer_service = transfer_service
      @copy_service = copy_service
    end

    # Creates a remote directory.
    # @return [Hash] result with :path
    def create(...)
      @crud_service.create_directory(...)
    end
    # Deletes a remote directory.
    # @return [Hash] result with :path
    def delete(...)
      @crud_service.delete(...)
    end
    # Checks if a remote directory exists.
    # @return [Boolean]
    def exists?(...)
      @crud_service.exists?(...)
    end
    # Lists subdirectories.
    # @return [Array<DirInfo>]
    def list(...)
      @crud_service.list(...)
    end
    # Lists files within a directory.
    # @return [Array<FileInfo>]
    def list_files(...)
      @crud_service.list_files(...)
    end
    # Fetches directory metadata.
    # @return [DirInfo]
    def metadata(...)
      @crud_service.metadata(...)
    end
    # Moves (renames) a directory within the same bucket.
    # @return [Hash] result with :from, :to
    def move(...)
      @crud_service.move(...)
    end

    # Renames a directory (deprecated, use move instead).
    # @return [Hash] result with :from, :to
    def rename(...)
      @logger.warn "[DEPRECATION] `rename` is deprecated — use `move` instead."
      @crud_service.rename(...)
    end

    # Uploads a local directory to a remote path.
    # @return [Hash] result with :directory, :files_uploaded, :total_size
    def upload(...)
      @transfer_service.upload(...)
    end
    # Downloads a remote directory to a local path.
    # @return [Hash] result with :directory, :local_path, :files_downloaded
    def download(...)
      @transfer_service.download(...)
    end
    # Downloads a directory snapshot with optional verification.
    # @return [Hash] result with :directory, :local_path, :files_downloaded, :manifest_path
    def snapshot_download(...)
      @transfer_service.snapshot_download(...)
    end

    # Copies files from a tree listing into the destination bucket.
    # @return [Hash] result with :files_copied, :total_size, :source
    def copy_from_tree(...)
      @copy_service.copy_from_tree(...)
    end
    # Copies files from a source repository into the destination bucket.
    # @return [Hash, Array<Hash>] copy result
    def copy_from_repo(...)
      @copy_service.copy_from_repo(...)
    end
    # Copies files/directories within the same bucket.
    # @return [Hash, Array] single result or array of results
    def copy(...)
      @copy_service.copy(...)
    end
    # Copies multiple source folders to the destination bucket.
    # @return [Hash] result with :folders, :xet_copied, :files_downloaded, :total, :skipped
    def copy_folders(...)
      @copy_service.copy_folders(...)
    end
  end
end
