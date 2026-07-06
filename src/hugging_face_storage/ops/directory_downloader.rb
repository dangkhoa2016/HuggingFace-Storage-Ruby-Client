# frozen_string_literal: true

require "fileutils"
require "net/http"

module HuggingFaceStorage
  # Downloads remote directory trees to a local filesystem path.
  # @api private
  # :nodoc:
  class DirectoryDownloader
    # Creates a new directory downloader.
    #
    # @param api_client [ApiClient] the API client
    # @param xet_downloader [XetDownloader] the Xet downloader
    # @param bucket_id [String] the bucket identifier
    # @param logger [Logger, nil] optional logger
    # @param config [Configuration, nil] optional configuration
    def initialize(api_client:, xet_downloader:, bucket_id:, logger: nil, config: nil)
      @api = api_client
      @xet_downloader = xet_downloader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @retryable = Retryable.new(logger: @logger)
    end

    # Downloads files from the bucket to a local directory.
    #
    # @param files [Array<DirInfo>] the files to download
    # @param normalized_base [String] the normalized base path for relative paths
    # @param local_dir [String] the local target directory
    # @param parallel [Integer] number of parallel download threads
    # @param cancel_token [CancelToken, nil] optional cancellation token
    def download(files, normalized_base, local_dir, parallel: 4, cancel_token: nil)
      FileUtils.mkdir_p(local_dir)

      if parallel > 1 && files.size > 1
        download_parallel(files, normalized_base, local_dir, parallel, cancel_token)
      else
        files.each do |file_info|
          cancel_token&.raise_if_cancelled!
          relative_path = file_info.path.sub(%r{^#{Regexp.escape(normalized_base)}/?}, "")
          local_path = safe_local_path(local_dir, relative_path, file_info.path)
          @logger.debug { "  Downloading: #{file_info.path} -> #{local_path}" }
          @xet_downloader.download_file(@bucket_id, file_info.path, local_path, cancel_token: cancel_token)
        end
      end
    end

    private

    # Worker loop that pops files from the queue and downloads them.
    #
    # @param queue [Queue] shared work queue
    # @param errors [Array<Hash>] shared error accumulator
    # @param mutex [Mutex] mutex for thread-safe error recording
    # @param internal_token [CancelToken] internal cancellation token
    # @param local_dir [String] local target directory
    # @param normalized_base [String] normalized base path for relative paths
    # @return [void]
    def download_worker(queue, errors, mutex, internal_token, local_dir, normalized_base)
      loop do
        break if internal_token.cancelled?

        file_info = begin
          queue.pop(true)
        rescue ThreadError
          nil
        end
        break unless file_info

        relative_path = file_info.path.sub(%r{^#{Regexp.escape(normalized_base)}/?}, "")
        begin
          local_path = safe_local_path(local_dir, relative_path, file_info.path)
        rescue Error => e
          record_worker_error(errors, mutex, internal_token, file_info, e, 0)
          break
        end

        begin
          @retryable.retry_with_backoff(@config, cancel_token: internal_token, logger: @logger) do
            @xet_downloader.download_file(@bucket_id, file_info.path, local_path,
                                          cancel_token: internal_token)
          end
        rescue CancelledError
          break
        rescue StandardError => e
          record_worker_error(errors, mutex, internal_token, file_info, e, @config.max_retries)
          break
        end
      end
    end

    # Records a worker error and cancels the internal token.
    #
    # @param errors [Array<Hash>] shared error accumulator
    # @param mutex [Mutex] mutex for synchronization
    # @param internal_token [CancelToken] internal cancellation token
    # @param file_info [DirInfo] the file that failed
    # @param error [StandardError] the error
    # @param retries [Integer] retry count
    # @return [void]
    def record_worker_error(errors, mutex, internal_token, file_info, error, retries)
      mutex.synchronize do
        errors << { file: file_info.path, error: error, retries: retries }
        internal_token.cancel!
      end
    end

    def raise_collected_errors(errors)
      unique_messages = errors.map { |e| e[:error].message }.uniq
      first_error = errors.first[:error]
      status = first_error.respond_to?(:status) ? first_error.status : nil
      detail = unique_messages.size == 1 ? unique_messages.first : unique_messages.join("; ")
      raise ApiError.new(
        message: "Failed to download #{errors.size} file(s): #{detail}",
        status: status,
        body: nil
      )
    end

    def safe_local_path(local_dir, relative_path, original_path)
      safe_root = File.realpath(local_dir)
      candidate = File.expand_path(File.join(safe_root, relative_path))
      return candidate if candidate.start_with?("#{safe_root}/") || candidate == safe_root

      raise Error, "Refusing to write outside target directory: #{original_path}"
    end

    # Downloads files in parallel using multiple threads.
    #
    # @param files [Array<DirInfo>] files to download
    # @param normalized_base [String] normalized base path for relative paths
    # @param local_dir [String] local target directory
    # @param num_threads [Integer] number of parallel threads
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [void]
    def download_parallel(files, normalized_base, local_dir, num_threads, cancel_token)
      queue, num_threads = build_download_batches(files, normalized_base, local_dir, num_threads)
      execute_download_workers(queue, num_threads, cancel_token, normalized_base, local_dir)
    end

    # Builds a thread-safe queue of download work items.
    #
    # @param files [Array<DirInfo>] files to download
    # @param _normalized_base [String] ignored
    # @param _local_dir [String] ignored
    # @param num_threads [Integer] requested thread count
    # @return [Array(Queue, Integer)] the queue and adjusted thread count
    def build_download_batches(files, _normalized_base, _local_dir, num_threads)
      queue = Queue.new
      files.each { |f| queue << f }
      [queue, [num_threads, files.size].min]
    end

    # Spawns worker threads and waits for all downloads to complete.
    #
    # @param queue [Queue] shared work queue
    # @param num_threads [Integer] number of worker threads
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param normalized_base [String] normalized base path for relative paths
    # @param local_dir [String] local target directory
    # @return [void]
    def execute_download_workers(queue, num_threads, cancel_token, normalized_base, local_dir)
      errors = [] # : Array[Hash[Symbol, untyped]]
      mutex = Mutex.new
      internal_token = CancelToken.new

      cancel_token&.on_cancel { internal_token.cancel! }

      threads = num_threads.times.map do
        Thread.new { download_worker(queue, errors, mutex, internal_token, local_dir, normalized_base) }
      end

      threads.each(&:join)

      raise_collected_errors(errors) if errors.any?
    end
  end
end
