# frozen_string_literal: true

require "digest/sha2"

module HuggingFaceStorage
  # Uploads chunked and hashed data (xorb + shard) to the CAS and registers files via the API.
  class XetDataUploader
    include TransportConfig

    # Initializes a new XetDataUploader.
    #
    # @param hasher [XetHasher] hasher instance
    # @param token_manager [XetTokenManager] token manager instance
    # @param api_client [ApiClient] API client instance
    # @param endpoint [String] CAS endpoint URL
    # @param config [Configuration] configuration object
    # @param logger [Logger] logger instance
    def initialize(hasher:, token_manager:, api_client:, endpoint:, config:, logger:, transport: nil)
      @hasher = hasher
      @token_manager = token_manager
      @api = api_client
      @endpoint = endpoint
      @config = config
      @logger = logger
      init_transport_config!(transport)
      @single_pipeline = SingleFileUploadPipeline.new(
        hasher: hasher, api_client: api_client, token_manager: token_manager,
        config: config, logger: logger, http_pool: @http_pool, retryable: @retryable
      )
      @batch_pipeline = BatchFileUploadPipeline.new(
        hasher: hasher, api_client: api_client, token_manager: token_manager,
        config: config, logger: logger, http_pool: @http_pool, retryable: @retryable
      )
      @shard_registrar = BatchShardRegistrar.new(
        hasher: hasher, api_client: api_client, token_manager: token_manager,
        config: config, logger: logger, http_pool: @http_pool, retryable: @retryable
      )
    end

    # Uploads data to CAS and registers the file.
    # Performs CDC chunking, hashing, xorb serialization, and shard registration.
    #
    # @param bucket_id [String] the bucket ID
    # @param data [String] binary data to upload
    # @param remote_path [String] remote file path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] hash with :xet_hash and :size
    def upload(bucket_id, data, remote_path, on_progress: nil, cancel_token: nil)
      @logger.debug { "Xet upload #{data.bytesize} bytes -> #{remote_path}" }
      cancel_token&.raise_if_cancelled!
      write_info = @token_manager.fetch_write_token(bucket_id)
      cas_url = write_info[:endpoint]

      @single_pipeline.stream_and_upload_data(
        bucket_id, data, cas_url, remote_path, on_progress, cancel_token
      ) { |source, cancel_token: nil| cdc_and_hash(source, cancel_token: cancel_token) }
    end

    # Represents the batch state for multi-file upload operations.
    XorbBatchState = Struct.new(
      :all_chunk_metas, :uploaded_xorbs, :file_metas,
      :pending_chunks, :pending_size, :global_chunk_idx,
      keyword_init: true
    )

    # Uploads a group of files in a single batch, sharing xorb packing and a common shard.
    #
    # @param bucket_id [String] the bucket ID
    # @param file_entries [Array<Hash>] file entries with :data/:local_path, :remote_path, :size
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array<Hash{Symbol => String, Integer}>] array of results with :path, :xet_hash, :size
    def upload_batch_group(bucket_id, file_entries, on_progress: nil, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      write_info = @token_manager.fetch_write_token(bucket_id)
      cas_url = write_info[:endpoint]

      state = XorbBatchState.new(
        all_chunk_metas: [], uploaded_xorbs: [], file_metas: [],
        pending_chunks: [], pending_size: 0, global_chunk_idx: 0
      )

      @batch_pipeline.process_file_entries(
        bucket_id, cas_url, state, file_entries,
        on_progress: on_progress, cancel_token: cancel_token
      ) do |entry, cancel_token: nil|
        cdc_and_hash(entry, cancel_token: cancel_token)
      end
      @batch_pipeline.flush_pending_xorb(bucket_id, cas_url, state, cancel_token: cancel_token)
      @logger.debug { "    Packed into #{state.uploaded_xorbs.size} xorb(s)" }

      @shard_registrar.build_representations(state)
      @shard_registrar.upload_and_register_shard(bucket_id, cas_url, state, cancel_token: cancel_token)
      @shard_registrar.register_batch_files(bucket_id, state, cancel_token: cancel_token)

      state.file_metas.map do |fm|
        { path: fm[:remote_path], xet_hash: Utils.hash_to_hex(fm[:file_hash]), size: fm[:size] }
      end
    end

    # Minimum data size in bytes to enable parallel CDC + SHA-256.
    # Below this threshold, sequential is faster due to thread dispatch overhead (~0.3ms).
    # At 256KB, SHA-256 takes ~0.5ms and CDC takes ~0.4ms — parallel saves ~0.4ms.
    PARALLEL_CDC_SHA256_THRESHOLD = 256 * 1024 # 256 KB

    private

    def cdc_and_hash(source, cancel_token: nil) # steep:ignore # rubocop:disable Lint/UnusedMethodArgument
      data = if source.is_a?(Hash)
               source = source #: Hash[Symbol, untyped]
               read_entry_data(source)
             else
               source #: String
             end
      data = data.b unless data.encoding == Encoding::ASCII_8BIT #: String

      # Parallel path: run CDC + BLAKE3 (native) and SHA-256 concurrently for large files.
      # Native cdc_and_hash combines CDC + BLAKE3 in single C call (~790 MB/s).
      # SHA-256 runs on persistent worker thread (~500 MB/s on 2 cores).
      sha256 = if data.bytesize > PARALLEL_CDC_SHA256_THRESHOLD
                 parallel_sha256(data)
               else
                 Digest::SHA256.digest(data)
               end
      chunk_ranges, hashes_concat = @hasher.cdc_and_hash_native(data)

      # Split concatenated hashes into array of 32-byte strings (unpack is 5x faster than scan)
      chunk_hashes = hashes_concat.unpack("a32" * (hashes_concat.bytesize / 32))
      chunk_lengths = chunk_ranges.map { |s, e| e - s }
      [chunk_ranges, data, chunk_hashes, chunk_lengths, sha256]
    end

    # Persistent SHA-256 worker thread that stays alive across uploads.
    # Eliminates Thread.new overhead for each file > 256KB.
    def parallel_sha256(data) # steep:ignore
      ensure_sha256_worker

      result = nil
      @sha256_mutex.synchronize do
        @sha256_request = data
        @sha256_result = nil
        @sha256_cv.signal
        @sha256_cv.wait(@sha256_mutex) until @sha256_result
        result = @sha256_result
        @sha256_result = nil
      end
      result
    end

    def ensure_sha256_worker
      return if @sha256_mutex

      @sha256_mutex = Mutex.new
      @sha256_cv = ConditionVariable.new
      @sha256_request = nil
      @sha256_result = nil

      @sha256_worker = Thread.new do
        loop do
          data = nil
          @sha256_mutex.synchronize do
            loop do
              break if @sha256_request

              @sha256_cv.wait(@sha256_mutex)
            end
            data = @sha256_request
            @sha256_request = nil
          end

          break unless data

          digest = Digest::SHA256.digest(data) # steep:ignore
          @sha256_mutex.synchronize do
            @sha256_result = digest
            @sha256_cv.signal
          end
        end
      end
      @sha256_worker.abort_on_exception = false
    end

    def read_entry_data(entry)
      return entry[:data] if entry.key?(:data)

      File.binread(entry[:local_path])
    end
  end
end
