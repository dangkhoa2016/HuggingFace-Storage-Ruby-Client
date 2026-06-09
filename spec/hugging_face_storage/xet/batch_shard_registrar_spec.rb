# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::BatchShardRegistrar do
  subject(:registrar) do
    described_class.new(
      hasher: hasher, api_client: api_client, token_manager: token_manager,
      config: config, logger: logger, http_pool: http_pool, retryable: retryable
    )
  end

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:config) { HuggingFaceStorage::Configuration.new(retry_delay: 0.001) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:http_pool) { instance_double(HuggingFaceStorage::HttpPool) }
  let(:retryable) { instance_double(HuggingFaceStorage::Retryable) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:cas_url) { TestHelpers::CAS_URL }
  let(:cancel_token) { HuggingFaceStorage::CancelToken.new }

  let(:state) do
    HuggingFaceStorage::XetDataUploader::XorbBatchState.new(
      all_chunk_metas: [
        { hash: ("\x01" * 32).b, length: 100 },
        { hash: ("\x02" * 32).b, length: 200 }
      ],
      uploaded_xorbs: [
        { hash: ("\x03" * 32).b, chunks: [
          { hash: ("\x01" * 32).b, length: 100 },
          { hash: ("\x02" * 32).b, length: 200 }
        ], serialized_size: 350 }
      ],
      file_metas: [
        { remote_path: "remote/a.txt", file_hash: ("\x04" * 32).b, sha256: ("\x05" * 32).b,
          chunk_start: 0, chunk_count: 2, size: 300 }
      ],
      pending_chunks: [], pending_size: 0, global_chunk_idx: 2
    )
  end

  before do
    allow(logger).to receive(:debug)
    allow(token_manager).to receive(:fetch_write_token).with(bucket_id).and_return(
      endpoint: TestHelpers::CAS_URL, token: "xet_write_token_abc", expiration: 9_999_999_999
    )

    http_resp = instance_double(Net::HTTPResponse, code: "200", body: "")
    allow(http_resp).to receive(:[]).and_return(nil)
    http_double = double("http")
    allow(http_double).to receive(:request).and_return(http_resp)
    allow(http_pool).to receive(:with_connection).and_yield(http_double).and_return(http_resp)
    allow(retryable).to receive(:retry_with_backoff).and_yield(0).and_return(http_resp)
    allow(api_client).to receive(:batch)
  end

  describe "#build_representations" do
    before do
      allow(HuggingFaceStorage::XetSerializer).to receive_message_chain(:new, :build_representation).and_return([{
        xorb_hash: ("\x03" * 32).b, index_start: 0, index_end: 2, length: 300, range_hash: ("\x06" * 32).b
      }])
    end

    it "builds representations for each file meta" do
      registrar.build_representations(state)

      expect(state.file_metas[0][:representation]).to be_an(Array)
      expect(state.file_metas[0][:representation].size).to eq(1)
    end
  end

  describe "#upload_and_register_shard" do
    before do
      allow(HuggingFaceStorage::XetSerializer).to receive_message_chain(:new,
:build_multi_file_shard).and_return("shard_data")
    end

    it "uploads shard to CAS" do
      registrar.upload_and_register_shard(bucket_id, cas_url, state, cancel_token: cancel_token)

      expect(http_pool).to have_received(:with_connection)
    end

    it "raises CancelledError when token is cancelled" do
      cancel_token.cancel!

      expect do
        registrar.upload_and_register_shard(bucket_id, cas_url, state, cancel_token: cancel_token)
      end.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end

  describe "#register_batch_files" do
    it "registers files via api.batch" do
      registrar.register_batch_files(bucket_id, state, cancel_token: cancel_token)

      expect(api_client).to have_received(:batch).with(
        bucket_id,
        [hash_including(type: "addFile", path: "remote/a.txt")],
        cancel_token: cancel_token
      )
    end

    it "raises CancelledError when token is cancelled" do
      cancel_token.cancel!

      expect do
        registrar.register_batch_files(bucket_id, state, cancel_token: cancel_token)
      end.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end
end
