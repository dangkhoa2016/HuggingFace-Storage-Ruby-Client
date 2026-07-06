# frozen_string_literal: true

require "digest/sha2"

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class SingleFileUploadPipeline
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

    def stream_and_upload_data(bucket_id, data, cas_url, remote_path, on_progress, cancel_token, &cdc_and_hash)
      chunk_data_list, xorb_hash, file_hash, sha256, representation, chunk_hashes, chunk_lengths =
        compute_single_file_metadata(data, cancel_token, &cdc_and_hash)

      cancel_token&.raise_if_cancelled!
      serializer = XetSerializer.new
      xorb_serialized = serializer.serialize_xorb(chunk_data_list)
      with_token_retry(bucket_id, label: "write") do |token|
        upload_xorb(cas_url, token, xorb_hash, xorb_serialized, cancel_token: cancel_token)
        true
      end

      cancel_token&.raise_if_cancelled!
      shard = serializer.build_shard(
        file_hash: file_hash, representation: representation,
        chunk_hashes: chunk_hashes, chunk_lengths: chunk_lengths,
        xorb_hash: xorb_hash, xorb_serialized_size: xorb_serialized.bytesize,
        sha256: sha256
      )
      with_token_retry(bucket_id, label: "write") do |token|
        upload_shard(cas_url, token, shard, cancel_token: cancel_token)
        true
      end

      register_single_file(bucket_id, Utils.hash_to_hex(file_hash), remote_path, data, on_progress, cancel_token)
    end

    private

    def compute_single_file_metadata(data, cancel_token, &cdc_and_hash)
      chunk_data_list, chunk_hashes, chunk_lengths, chunks_info = yield(data, cancel_token: cancel_token)
      xorb_hash = @hasher.compute_xorb_hash(chunks_info)
      file_hash = @hasher.compute_file_hash(xorb_hash)
      sha256 = Digest::SHA256.digest(data)
      range_hash = @hasher.compute_verification_hash(chunk_hashes)
      representation = [{
        xorb_hash: xorb_hash,
        index_start: 0, index_end: chunk_hashes.length,
        length: chunk_lengths.sum, range_hash: range_hash
      }]
      [chunk_data_list, xorb_hash, file_hash, sha256, representation, chunk_hashes, chunk_lengths]
    end

    def register_single_file(bucket_id, file_hash_hex, remote_path, data, on_progress, cancel_token)
      mtime = (Time.now.to_f * 1000).to_i
      cancel_token&.raise_if_cancelled!
      @api.batch(
        bucket_id,
        [{ type: ApiOperations::ADD_FILE, path: remote_path, xetHash: file_hash_hex,
           mtime: mtime }],
        cancel_token: cancel_token
      )
      on_progress&.call(remote_path, data.bytesize, data.bytesize)
      @logger.debug { "Xet upload complete: #{remote_path} (hash=#{file_hash_hex})" }
      { xet_hash: file_hash_hex, size: data.bytesize }
    end
  end
end
