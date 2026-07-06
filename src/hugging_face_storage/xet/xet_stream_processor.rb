# frozen_string_literal: true

require "digest/sha2"
require "net/http"
require "uri"
require "json"
require_relative "gearhash_table"

module HuggingFaceStorage
  # Processes streaming uploads — CDC-chunks data, builds xorbs, and uploads to CAS.
  class XetStreamProcessor
    include CasClient
    include TransportConfig

    # Initializes a new XetStreamProcessor.
    #
    # @param hasher [XetHasher] hasher instance
    # @param serializer [XetSerializer] serializer instance
    # @param logger [Logger, nil] logger instance
    # @param config [Configuration, nil] configuration object
    # @param transport [HTTPTransport, nil] optional HTTP transport
    def initialize(hasher:, serializer:, logger: nil, config: nil, transport: nil)
      @hasher = hasher
      @serializer = serializer
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
      init_transport_config!(transport)
      @cdc_chunker = CdcChunker.new(gearhash_table: GEARHASH_TABLE)
    end

    # Streams data from a block, chunking and uploading to CAS.
    #
    # @param remote_path [String] remote file path
    # @param cas_url [String] CAS server URL
    # @param token [String] CAS auth token
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @yield [Proc] yields a write_chunk callable
    # @return [Hash{Symbol => String, Integer}] result with :xet_hash, :size, :remote_path
    def stream_upload(remote_path, cas_url:, token:, cancel_token: nil, &block)
      cancel_token&.raise_if_cancelled!
      @all_chunk_pairs = []
      @uploaded_xorbs = []
      sha256_ctx = Digest::SHA256.new
      total_bytes = 0
      @pending_xorb_chunks = []
      @pending_xorb_size = 0
      rep_builder = @serializer.stream_representation_builder

      yield lambda { |http_chunk|
        http_chunk = http_chunk.b
        sha256_ctx << http_chunk
        total_bytes += http_chunk.bytesize
        @cdc_chunker.feed(http_chunk) do |chunk|
          commit_chunk_to_xorb(chunk, rep_builder, cas_url, token, cancel_token: cancel_token)
        end
      }

      @cdc_chunker.finalize do |chunk|
        commit_chunk_to_xorb(chunk, rep_builder, cas_url, token, cancel_token: cancel_token)
      end
      cancel_token&.raise_if_cancelled!
      flush_current_xorb(cas_url, token, rep_builder, cancel_token: cancel_token)
      finalize_and_upload(remote_path, sha256_ctx, total_bytes, cas_url, token, rep_builder, cancel_token: cancel_token)
    end

    private

    # Flushes pending chunks into a xorb, uploads it to CAS, and updates the representation builder.
    #
    # @param cas_url [String] CAS server URL
    # @param token [String] CAS auth token
    # @param rep_builder [XetStreamRepresentationBuilder] representation builder
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [void]
    def flush_current_xorb(cas_url, token, rep_builder, cancel_token: nil)
      return if @pending_xorb_chunks.empty?

      cancel_token&.raise_if_cancelled!
      serialized = @serializer.serialize_xorb(@pending_xorb_chunks.map { |c| c[:data] })
      chunks_info = @pending_xorb_chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      xorb_hash = @hasher.compute_xorb_hash(chunks_info)
      upload_xorb(cas_url, token, xorb_hash, serialized, cancel_token: cancel_token)
      @uploaded_xorbs << { hash: xorb_hash, chunks: chunks_info, serialized_size: serialized.bytesize }
      @all_chunk_pairs.concat(@pending_xorb_chunks.map { |c| [c[:hash], c[:length]] })
      rep_builder.finalize_xorb(xorb_hash)
      @pending_xorb_chunks.clear
      @pending_xorb_size = 0
    end

    # Hashes a chunk and commits it to the pending xorb, flushing if size or count limits are reached.
    #
    # @param chunk_bytes [String] binary chunk data
    # @param rep_builder [XetStreamRepresentationBuilder] representation builder
    # @param cas_url [String] CAS server URL
    # @param token [String] CAS auth token
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [void]
    def commit_chunk_to_xorb(chunk_bytes, rep_builder, cas_url, token, cancel_token: nil)
      chunk_bytes = chunk_bytes.b
      h = @hasher.blake3_keyed(XetHasher::DATA_KEY, chunk_bytes)
      entry = { data: chunk_bytes, hash: h, length: chunk_bytes.bytesize }
      chunk_total = XetHasher::CHUNK_HEADER_SIZE + chunk_bytes.bytesize
      if @pending_xorb_size + chunk_total > XetHasher::XORB_MAX_SIZE || @pending_xorb_chunks.length >= XetHasher::XORB_MAX_CHUNKS
        flush_current_xorb(cas_url, token, rep_builder, cancel_token: cancel_token)
      end
      rep_builder.start_xorb if @pending_xorb_chunks.empty?
      rep_builder.add_chunk(h, chunk_bytes.bytesize)
      @pending_xorb_chunks << entry
      @pending_xorb_size += chunk_total
    end

    # Finalizes the file hash, builds and uploads the shard, and returns the result.
    #
    # @param remote_path [String] remote file path
    # @param sha256_ctx [Digest::SHA256] SHA-256 context with accumulated data
    # @param total_bytes [Integer] total uploaded bytes
    # @param cas_url [String] CAS server URL
    # @param token [String] CAS auth token
    # @param rep_builder [XetStreamRepresentationBuilder] representation builder
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Hash{Symbol => String, Integer}] result with :xet_hash, :size, :remote_path
    def finalize_and_upload(remote_path, sha256_ctx, total_bytes, cas_url, token, rep_builder, cancel_token: nil)
      xorb_hash_for_file = @hasher.compute_xorb_hash(@all_chunk_pairs)
      file_hash = @hasher.compute_file_hash(xorb_hash_for_file)
      sha256 = sha256_ctx.digest

      representation = rep_builder.finalize
      file_meta = {
        remote_path: remote_path,
        file_hash: file_hash,
        sha256: sha256,
        representation: representation,
        chunk_start: 0,
        chunk_count: @all_chunk_pairs.length,
        size: total_bytes,
      }
      cancel_token&.raise_if_cancelled!
      shard = @serializer.build_multi_file_shard([file_meta], @uploaded_xorbs)
      upload_shard(cas_url, token, shard, cancel_token: cancel_token)

      @logger.debug { "Streaming upload complete: #{remote_path} (#{total_bytes} bytes)" }
      { xet_hash: Utils.hash_to_hex(file_hash), size: total_bytes, remote_path: remote_path }
    end
  end
end
