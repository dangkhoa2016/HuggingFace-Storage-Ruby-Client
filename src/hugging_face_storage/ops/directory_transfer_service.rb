# frozen_string_literal: true

module HuggingFaceStorage
  # Handles directory transfer operations: upload, download, snapshot_download.
  class DirectoryTransferService
    include Instrumentation

    # Initializes a new DirectoryTransferService.
    #
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] xet uploader
    # @param xet_downloader [XetDownloader] xet downloader
    # @param bucket_id [String] the bucket identifier
    # @param file_manager [FileManager] file listing interface
    # @param config [Configuration, nil] configuration object
    # @param logger [Logger, nil] logger instance
    # @param metrics_registry [MetricsRegistry, nil] metrics registry
    # @param notifications [Notifications::Channel, nil] notifications channel
    def initialize(api_client:, xet_uploader:, xet_downloader:, bucket_id:, file_manager:, config: nil, logger: nil,
                   metrics_registry: nil, notifications: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @xet_downloader = xet_downloader
      @bucket_id = bucket_id
      @files = file_manager
      @config = config || Configuration.default
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Downloads a remote directory tree to a local path.
    #
    # @param path [String] remote directory path
    # @param local_dir [String] local destination directory
    # @param parallel [Integer] number of parallel downloads (default 4)
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :directory, :files_downloaded, :local_path
    def download(path, local_dir, parallel: 4, cancel_token: nil)
      normalized = Paths.normalize(path)
      @logger.info("Downloading directory: #{normalized} -> #{local_dir}")
      files = @files.list(prefix: normalized, recursive: true)

      raise NotFoundError, "No files found in directory: #{path}" if files.empty?

      downloader = DirectoryDownloader.new(
        api_client: @api, xet_downloader: @xet_downloader, bucket_id: @bucket_id, logger: @logger, config: @config
      )
      downloader.download(files, normalized, local_dir, parallel: parallel, cancel_token: cancel_token)

      @logger.info("Downloaded #{files.size} file(s) to #{local_dir}")
      @notifications.publish(:directory_downloaded, directory: normalized, files_downloaded: files.size,
                                                    local_path: local_dir)
      @metrics_registry.increment(:operations)
      { directory: normalized, files_downloaded: files.size, local_path: local_dir }
    end

    # Uploads a local directory to a remote path.
    #
    # @param local_dir [String] local directory path
    # @param remote_path [String] remote destination path
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :directory, :files_uploaded, :total_size
    def upload(local_dir, remote_path, exclude: nil, cancel_token: nil)
      local_dir = local_dir.to_s.sub(%r{/+\z}, "")
      remote_base = Paths.normalize(remote_path)
      raise Error, "Local directory not found: #{local_dir}" unless Dir.exist?(local_dir)

      uploader = DirectoryUploader.new(
        api_client: @api, xet_uploader: @xet_uploader, bucket_id: @bucket_id, logger: @logger, config: @config
      )
      result = uploader.upload(local_dir, remote_base, exclude: exclude, cancel_token: cancel_token)
      @notifications.publish(:directory_uploaded, directory: remote_base, local_path: local_dir)
      @metrics_registry.increment(:operations)
      result
    end

    # Downloads a directory snapshot with an optional integrity manifest.
    #
    # @param remote_path [String] remote directory path
    # @param local_dir [String] local destination directory
    # @param verify [Boolean] verify file sizes after download (default false)
    # @return [Hash{Symbol => String, Integer, Boolean}] snapshot result
    def snapshot_download(remote_path, local_dir, verify: false)
      snapshot = Snapshot.new(
        api_client: @api, xet_downloader: @xet_downloader,
        file_manager: @files, directory_manager: self,
        bucket_id: @bucket_id, logger: @logger, config: @config
      )
      snapshot.download(remote_path, local_dir, verify: verify)
    end
  end
end
