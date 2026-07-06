# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::SingleFileUploadPipeline do
  subject(:pipeline) do
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
  let(:data) { "test data content" }
  let(:remote_path) { "remote/test.txt" }
  let(:xorb_hash) { ("\x02" * 32).b }
  let(:file_hash) { ("\x03" * 32).b }
  let(:chunk_hash) { ("\x04" * 32).b }
  let(:xorb_serialized) { "xorb_binary_data" }
  let(:shard_data) { "shard_binary_data" }

  let(:cdc_result) do
    [[data], [chunk_hash], [data.bytesize], [{ hash: chunk_hash, length: data.bytesize }]]
  end

  before do
    allow(logger).to receive(:debug)
    allow(hasher).to receive(:compute_xorb_hash).and_return(xorb_hash)
    allow(hasher).to receive(:compute_file_hash).and_return(file_hash)
    allow(hasher).to receive(:compute_verification_hash).and_return(("\x05" * 32).b)

    allow(HuggingFaceStorage::XetSerializer).to receive_message_chain(:new, :serialize_xorb).and_return(xorb_serialized)
    allow(HuggingFaceStorage::XetSerializer).to receive_message_chain(:new, :build_shard).and_return(shard_data)

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

  describe "#stream_and_upload_data" do
    it "uploads data, xorb, shard and registers file" do
      result = pipeline.stream_and_upload_data(bucket_id, data, cas_url, remote_path, nil,
cancel_token) do |d, cancel_token:|
        cdc_result
      end

      expect(result).to eq({ xet_hash: file_hash.unpack1("H*"), size: data.bytesize })
    end

    it "calls api.batch to register the file" do
      pipeline.stream_and_upload_data(bucket_id, data, cas_url, remote_path, nil, cancel_token) do |d, cancel_token:|
        cdc_result
      end

      file_hash_hex = file_hash.unpack1("H*")
      expect(api_client).to have_received(:batch).with(
        bucket_id, [hash_including(type: "addFile", path: remote_path, xetHash: file_hash_hex)],
        cancel_token: cancel_token
      )
    end

    it "raises CancelledError when token is cancelled" do
      cancel_token.cancel!

      expect do
        pipeline.stream_and_upload_data(bucket_id, data, cas_url, remote_path, nil, cancel_token) do |d, cancel_token:|
          cdc_result
        end
      end.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end

  describe "#compute_single_file_metadata" do
    it "computes metadata from cdc result" do
      result = pipeline.send(:compute_single_file_metadata, data, cancel_token) do |d, cancel_token:|
        cdc_result
      end

      expect(result[0]).to eq([data])
      expect(result[1]).to eq(xorb_hash)
      expect(result[2]).to eq(file_hash)
      expect(result[3].bytesize).to eq(32) # sha256
      expect(result[4]).to be_an(Array)
      expect(result[5]).to eq([chunk_hash])
      expect(result[6]).to eq([data.bytesize])
    end
  end
end
