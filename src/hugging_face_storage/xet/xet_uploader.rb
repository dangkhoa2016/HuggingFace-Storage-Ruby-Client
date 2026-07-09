# frozen_string_literal: true

module HuggingFaceStorage
  # Uploads files and data to Xet storage, coordinating hashing, serialization, and CAS upload.
  # rubocop:disable Metrics/ClassLength
  class XetUploader
    include CasClient
    include Instrumentation
    include TokenRetryable
    include TransportConfig

    # Initializes a new XetUploader.
    #
    # @param hasher [XetHasher] hasher instance
    # @param serializer [XetSerializer] serializer instance
    # @param token_manager [XetTokenManager] token manager instance
    # @param api_client [ApiClient] API client instance
    # @param endpoint [String] API endpoint URL
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    # @param metrics_registry [Object, nil] metrics registry
    # @param notifications [Module, nil] notifications module
    def initialize(hasher:, serializer:, token_manager:, api_client:, endpoint:, logger: nil, config: nil,
                   metrics_registry: nil, notifications: nil, transport: nil)
      @hasher = hasher
      @serializer = serializer
      @token_manager = token_manager
      @api = api_client
      @endpoint = endpoint
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      @metrics_registry = metrics_registry
      @notifications = notifications
      init_transport_config!(transport)
      @data_uploader = XetDataUploader.new(
        hasher: @hasher, token_manager: @token_manager,
        api_client: @api, endpoint: @endpoint, config: @config, logger: @logger,
        transport: @transport
      )
    end

    # Uploads a local file to Xet storage, using streaming for large files.
    #
    # @param bucket_id [String] the bucket ID
    # @param local_path [String] local file path
    # @param remote_path [String] remote destination path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :xet_hash and :size
    def upload_file_to_path(bucket_id, local_path, remote_path, on_progress: nil, cancel_token: nil)
      file_size = File.size(local_path)
      if file_size > @config.stream_threshold
        @logger.info("Streaming upload large file (#{Utils.human_size(file_size)}): #{local_path} -> #{remote_path}")
        stream_upload_file(bucket_id, local_path, remote_path, on_progress: on_progress, cancel_token: cancel_token)
      else
        data = File.binread(local_path)
        upload_data(bucket_id, data, remote_path, on_progress: on_progress, cancel_token: cancel_token)
      end
    end

    # Uploads raw binary data to Xet storage.
    #
    # @param bucket_id [String] the bucket ID
    # @param data [String] binary data to upload
    # @param remote_path [String] remote destination path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :xet_hash and :size
    def upload_bytes_to_path(bucket_id, data, remote_path, on_progress: nil, cancel_token: nil)
      upload_data(bucket_id, data.b, remote_path, on_progress: on_progress, cancel_token: cancel_token)
    end

    # Uploads a batch of files, splitting into memory-limited groups as needed.
    #
    # @param bucket_id [String] the bucket ID
    # @param file_entries [Array<Hash>] file entries with :data/:local_path, :remote_path, :size
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array<Hash{Symbol => String, Integer}>] array of results with :path, :xet_hash, :size
    def upload_batch(bucket_id, file_entries, on_progress: nil, cancel_token: nil)
      total_bytes = file_entries.sum { |e| e[:size] || 0 }
      instrument("upload_batch", bucket_id: bucket_id, files: file_entries.size, bytes_uploaded: total_bytes) do
        perform_upload_batch(bucket_id, file_entries, on_progress: on_progress, cancel_token: cancel_token)
      end
    end

    # Uploads binary data to Xet storage via the data uploader.
    #
    # @param bucket_id [String] the bucket ID
    # @param data [String] binary data to upload
    # @param remote_path [String] remote destination path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :xet_hash and :size
    def upload_data(bucket_id, data, remote_path, on_progress: nil, cancel_token: nil)
      instrument("upload_data", bucket_id: bucket_id, path: remote_path, size: data.bytesize,
                                bytes_uploaded: data.bytesize) do
        @data_uploader.upload(bucket_id, data, remote_path, on_progress: on_progress, cancel_token: cancel_token)
      end
    end

    # Streams data from a download block and uploads it to Xet storage.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote destination path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [Proc] yields a write_chunk callable
    # @return [Object] result from the streaming upload
    def stream_download_and_upload(bucket_id, remote_path, cancel_token: nil, &download_block)
      instrument("stream_download_and_upload", bucket_id: bucket_id, path: remote_path) do
        perform_stream_download_and_upload(bucket_id, remote_path, cancel_token: cancel_token, &download_block)
      end
    end

    private

    # Splits file entries into memory-limited groups and uploads each group.
    #
    # @param bucket_id [String] the bucket ID
    # @param file_entries [Array<Hash>] file entries with :size, :data/:local_path, :remote_path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array<Hash{Symbol => String, Integer}>] array of results
    def perform_upload_batch(bucket_id, file_entries, on_progress: nil, cancel_token: nil)
      return [] if file_entries.empty?

      total_size = file_entries.sum { |e| e[:size] }
      @logger.info("Batch upload: #{file_entries.size} file(s), #{Utils.human_size(total_size)}")

      groups = prepare_batch_payload(file_entries)

      # @type var results: Array[Hash[Symbol, (String | Integer)]]
      results = []
      groups.each_with_index do |group, gi|
        cancel_token&.raise_if_cancelled!
        @logger.info(
          "  Processing group #{gi + 1}/#{groups.size} " \
          "(#{group.size} file(s), #{Utils.human_size(group.sum { |e| e[:size] })})"
        )
        results.concat(@data_uploader.upload_batch_group(bucket_id, group, on_progress: on_progress,
                                                                           cancel_token: cancel_token))
      end

      @logger.info("Batch upload complete: #{results.size} file(s)")
      results
    end

    # Groups file entries into batches respecting the batch memory limit.
    #
    # @param file_entries [Array<Hash>] file entries with :size
    # @return [Array<Array<Hash>>] groups of file entries
    def prepare_batch_payload(file_entries)
      groups = [] # : Array[Array[Hash[Symbol, untyped]]]
      current_group = [] # : Array[Hash[Symbol, untyped]]
      current_size = 0

      file_entries.each do |entry|
        entry_size = entry[:size]
        if current_size + entry_size > @config.batch_memory_limit && !current_group.empty?
          groups << current_group
          current_group = []
          current_size = 0
        end
        current_group << entry
        current_size += entry_size
      end
      groups << current_group unless current_group.empty?

      if groups.size > 1
        @logger.info(
          "  Split into #{groups.size} group(s) to limit memory usage " \
          "(#{Utils.human_size(@config.batch_memory_limit)}/group)"
        )
      end

      groups
    end

    # Reports progress for a single batch entry.
    #
    # @param entry [Hash] file entry with :remote_path and :size
    # @param on_progress [Proc, nil] progress callback
    # @param index [Integer] entry index
    # @param _total [Integer] total entries (unused)
    # @return [void]
    def report_batch_progress(entry, on_progress, index, _total)
      on_progress&.call(index, entry[:remote_path], entry[:size])
    end

    # Performs a streaming download-then-upload by bridging the download block to stream_upload_core.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote destination path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [Proc] yields a write_chunk callable
    # @return [Hash{Symbol => String, Integer}] upload result
    def perform_stream_download_and_upload(bucket_id, remote_path, cancel_token: nil, &download_block)
      @logger.debug { "Streaming upload: #{remote_path}" }
      stream_upload_core(bucket_id, remote_path, cancel_token: cancel_token) do |write_chunk|
        download_block.call(&write_chunk)
      end
    end

    # Streams a local file to Xet storage, reading and uploading in configurable chunks.
    #
    # @param bucket_id [String] the bucket ID
    # @param local_path [String] local file path
    # @param remote_path [String] remote destination path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] upload result
    def stream_upload_file(bucket_id, local_path, remote_path, on_progress: nil, cancel_token: nil)
      file_size = File.size(local_path)
      last_progress = 0

      stream_upload_core(bucket_id, remote_path, cancel_token: cancel_token) do |write_chunk|
        File.open(local_path, "rb") do |f|
          while (chunk = f.read(@config.stream_chunk_size))
            cancel_token&.raise_if_cancelled!
            write_chunk.call(chunk)
            next unless on_progress

            progress = f.pos
            if progress - last_progress >= 1024 * 1024 || progress >= file_size
              on_progress.call(remote_path, progress, file_size)
              last_progress = progress
            end
          end
        end
      end
    end

    # Core streaming upload: fetches write token, processes via XetStreamProcessor, and registers.
    #
    # @param bucket_id [String] the bucket ID
    # @param remote_path [String] remote destination path
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [Proc] yields a write_chunk callable
    # @return [Hash{Symbol => String, Integer}] upload result
    def stream_upload_core(bucket_id, remote_path, cancel_token: nil, &block)
      cancel_token&.raise_if_cancelled!
      write_info = @token_manager.fetch_write_token(bucket_id)

      processor = XetStreamProcessor.new(
        hasher: @hasher, serializer: @serializer, logger: @logger, config: @config,
        transport: @transport
      )
      result = processor.stream_upload(
        remote_path,
        cas_url: write_info[:endpoint],
        token: write_info[:token],
        cancel_token: cancel_token,
        &block
      )

      mtime = (Time.now.to_f * 1000).to_i
      @api.batch(bucket_id, [{
        type: ApiOperations::ADD_FILE, path: result[:remote_path],
        xetHash: result[:xet_hash], mtime: mtime
      }], cancel_token: cancel_token)

      @logger.debug { "Streaming upload complete: #{remote_path} (#{result[:size]} bytes)" }
      result
    end
  end
  # rubocop:enable Metrics/ClassLength
end
