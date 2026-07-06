# frozen_string_literal: true

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class BatchShardRegistrar
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

    def build_representations(state)
      serializer = XetSerializer.new
      state.file_metas.each do |fm|
        fm[:representation] = serializer.build_representation(
          fm[:chunk_start], fm[:chunk_count], state.all_chunk_metas, state.uploaded_xorbs
        )
      end
    end

    def upload_and_register_shard(bucket_id, cas_url, state, cancel_token: nil)
      cancel_token&.raise_if_cancelled!
      serializer = XetSerializer.new
      shard = serializer.build_multi_file_shard(state.file_metas, state.uploaded_xorbs)
      with_token_retry(bucket_id, label: "write") do |token|
        upload_shard(cas_url, token, shard, cancel_token: cancel_token)
        true
      end
    end

    def register_batch_files(bucket_id, state, cancel_token: nil)
      mtime = (Time.now.to_f * 1000).to_i
      operations = state.file_metas.map do |fm|
        { type: ApiOperations::ADD_FILE, path: fm[:remote_path], xetHash: Utils.hash_to_hex(fm[:file_hash]), mtime: mtime }
      end
      cancel_token&.raise_if_cancelled!
      @api.batch(bucket_id, operations, cancel_token: cancel_token)
    end
  end
end
