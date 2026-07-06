# frozen_string_literal: true

require "digest/sha2"

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class BatchFileUploadPipeline
    include CasClient
    include TokenRetryable

    def initialize(hasher:, api_client:, token_manager:, config:, logger:, http_pool:, retryable:)
      @hasher = hasher
      @api = api_client
      @token_manager = token_manager
      @config = config
      @logger = logger
      @http_pool = http_pool
      @retryable = retryable
    end

    def process_file_entries(bucket_id, cas_url, state, file_entries, on_progress: nil, cancel_token: nil,
                             &cdc_and_hash)
      file_entries.each_with_index do |entry, file_idx|
        process_single_file_entry(bucket_id, cas_url, state, entry, file_idx, on_progress, cancel_token, &cdc_and_hash)
      end
    end

    def process_single_file_entry(bucket_id, cas_url, state, entry, file_idx, on_progress, cancel_token, &cdc_and_hash)
      cancel_token&.raise_if_cancelled!
      on_progress&.call(file_idx, entry[:remote_path], entry[:size])
      chunks_data, chunk_hashes, chunk_lengths, chunks_info = yield(entry, cancel_token: cancel_token)
      start_idx = state.global_chunk_idx

      chunk_count = process_file_chunks(bucket_id, cas_url, state, chunks_data, chunk_hashes, chunk_lengths,
                                        cancel_token)

      xorb_hash = @hasher.compute_xorb_hash(chunks_info)
      file_hash = @hasher.compute_file_hash(xorb_hash)
      file_data = entry.key?(:data) ? entry[:data] : File.binread(entry[:local_path])
      sha256 = Digest::SHA256.digest(file_data)

      state.file_metas << {
        remote_path: entry[:remote_path], file_hash: file_hash, sha256: sha256,
        chunk_start: start_idx, chunk_count: chunk_count, size: entry[:size]
      }
    end

    def process_file_chunks(bucket_id, cas_url, state, chunks_data, chunk_hashes, chunk_lengths, cancel_token)
      chunk_count = 0
      chunks_data.each_with_index do |cd, ci|
        h = chunk_hashes[ci]
        l = chunk_lengths[ci]
        chunk_total = XetHasher::CHUNK_HEADER_SIZE + l

        if state.pending_size + chunk_total > XetHasher::XORB_MAX_SIZE ||
           state.pending_chunks.length >= XetHasher::XORB_MAX_CHUNKS
          flush_pending_xorb(bucket_id, cas_url, state, cancel_token: cancel_token)
        end

        state.pending_chunks << { data: cd, hash: h, length: l }
        state.pending_size += chunk_total
        state.all_chunk_metas << { hash: h, length: l }
        state.global_chunk_idx += 1
        chunk_count += 1
      end
      chunk_count
    end

    def flush_pending_xorb(bucket_id, cas_url, state, cancel_token: nil)
      return if state.pending_chunks.empty?

      serializer = XetSerializer.new
      data = serializer.serialize_xorb(state.pending_chunks.map { |c| c[:data] })
      chunks_info = state.pending_chunks.map { |c| { hash: c[:hash], length: c[:length] } }
      xorb_hash = @hasher.compute_xorb_hash(chunks_info)
      with_token_retry(bucket_id, label: "write") do |token|
        upload_xorb(cas_url, token, xorb_hash, data, cancel_token: cancel_token)
        true
      end
      state.uploaded_xorbs << { hash: xorb_hash, chunks: chunks_info, serialized_size: data.bytesize }
      state.pending_chunks.clear
      state.pending_size = 0
    end
  end
end
