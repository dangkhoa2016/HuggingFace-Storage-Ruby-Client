# frozen_string_literal: true

module HuggingFaceStorage
  # Copies files from a HuggingFace repo to a storage bucket.
  # @api private
  # :nodoc:
  class RepoFileCopier
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] uploader for copied data
    # @param bucket_id [String] destination bucket identifier
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration
    def initialize(api_client:, xet_uploader:, bucket_id:, logger: nil, config: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
    end

    # Downloads files from a repo, uploading small entries in batch and streaming large ones.
    #
    # @param pending_downloads [Array<Hash>] list of download specs with :source_type, :source_repo, etc.
    # @param on_progress [Proc, nil] progress callback (called with path:, downloaded:)
    # @param on_large_complete [Proc, nil] callback for each large file completion
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] keys :downloaded (count)
    def copy(pending_downloads, on_progress: nil, on_large_complete: nil, cancel_token: nil)
      return { downloaded: 0 } if pending_downloads.empty?

      small = pending_downloads.select { |d| (d[:size] || 0) <= @config.small_size_threshold }
      large = pending_downloads.select { |d| (d[:size] || 0) > @config.small_size_threshold }
      downloaded_count = 0

      if small.any?
        downloaded_count = fetch_and_process_batch(small, cancel_token: cancel_token,
                                                          on_progress: on_progress, start_count: downloaded_count)
      end

      if large.any?
        large.each do |dl|
          downloaded_count += 1
          download_single_file(dl, cancel_token: cancel_token, on_progress: on_progress,
                                   on_large_complete: on_large_complete, current_count: downloaded_count)
        end
      end

      { downloaded: downloaded_count }
    end

    # Downloads a batch of small files and uploads them via the Xet uploader.
    #
    # @param batch [Array<Hash>] small file download specifications
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param on_progress [Proc, nil] progress callback
    # @param start_count [Integer] starting download count
    # @return [Integer] updated download count
    def fetch_and_process_batch(batch, cancel_token:, on_progress:, start_count: 0)
      count = start_count
      file_entries = batch.map do |dl|
        cancel_token&.raise_if_cancelled!
        @logger.info("    Downloading: #{dl[:source_path]}  (#{Utils.human_size(dl[:size] || 0)})")
        data = @api.download_repo_file(
          dl[:source_type], dl[:source_repo], dl[:source_path],
          revision: dl[:revision], cancel_token: cancel_token
        )
        count += 1
        on_progress&.call(path: dl[:source_path], downloaded: count)
        { data: data, remote_path: dl[:destination], size: data.bytesize }
      end
      @xet_uploader.upload_batch(@bucket_id, file_entries, cancel_token: cancel_token)
      count
    end

    # Downloads a single large file via streaming and uploads it to the bucket.
    #
    # @param item [Hash] download specification with :source_type, :source_repo, :source_path, :destination
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param on_progress [Proc, nil] progress callback
    # @param on_large_complete [Proc, nil] callback invoked with the resulting operation
    # @param current_count [Integer] current download count for progress tracking
    # @return [void]
    def download_single_file(item, cancel_token:, on_progress:, on_large_complete:, current_count:)
      mtime = (Time.now.to_f * 1000).to_i
      cancel_token&.raise_if_cancelled!
      on_progress&.call(path: item[:source_path], downloaded: current_count)
      result = @xet_uploader.stream_download_and_upload(@bucket_id, item[:destination],
                                                        cancel_token: cancel_token) do |&write_chunk|
        @api.download_repo_file_streaming(item[:source_type], item[:source_repo], item[:source_path],
                                          revision: item[:revision], cancel_token: cancel_token, &write_chunk)
      end
      on_large_complete&.call({
        type: ApiOperations::ADD_FILE, path: result[:remote_path], xetHash: result[:xet_hash], mtime: mtime
      })
    end
  end
end
