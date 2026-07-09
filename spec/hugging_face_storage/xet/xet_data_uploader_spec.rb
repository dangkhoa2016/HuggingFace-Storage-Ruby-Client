# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetDataUploader do
  subject(:uploader) do
    described_class.new(
      hasher: hasher,
      token_manager: token_manager,
      api_client: api_client,
      endpoint: TestHelpers::CAS_URL,
      config: config,
      logger: logger
    )
  end

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:serializer) { instance_double(HuggingFaceStorage::XetSerializer) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:config) { instance_double(HuggingFaceStorage::Configuration) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger) }

  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:data) { "hello world" }
  let(:remote_path) { "notes/hello.txt" }

  let(:xorb_hash) { ("\x02" * 32).b }
  let(:file_hash) { ("\x03" * 32).b }

  before do
    allow(HuggingFaceStorage::XetSerializer).to receive(:new).and_return(serializer)
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(token_manager).to receive(:fetch_write_token).with(bucket_id).and_return(
      endpoint: TestHelpers::CAS_URL, token: "xet_write_token_abc", expiration: 9_999_999_999
    )
    allow(hasher).to receive(:cdc_chunk).with(data).and_return([[0, data.bytesize]])
    allow(hasher).to receive(:batch_blake3_keyed).and_return([("\x01" * 32).b])
    allow(hasher).to receive(:compute_xorb_hash).and_return(xorb_hash)
    allow(hasher).to receive(:compute_file_hash).and_return(file_hash)
    allow(hasher).to receive(:compute_verification_hash).and_return(("\x04" * 32).b)
    allow(serializer).to receive(:serialize_xorb).and_return("xorb_serialized")
    allow(serializer).to receive(:build_shard).and_return("shard_data")
    allow(api_client).to receive(:batch)
  end

  # ── Constructor ──

  describe "#initialize" do
    it "creates an instance with all required dependencies" do
      expect { uploader }.not_to raise_error
    end

    it "does not create http_pool when transport is provided" do
      transport = double("transport", http_pool: nil, retryable: nil)
      expect(HuggingFaceStorage::HttpPool).not_to receive(:new)
      expect(HuggingFaceStorage::Retryable).not_to receive(:new)
      described_class.new(
        hasher: hasher, token_manager: token_manager,
        api_client: api_client, endpoint: TestHelpers::CAS_URL, config: config,
        logger: logger, transport: transport
      )
    end
  end

  # ── Upload ──

  describe "#upload" do
    let(:pipeline) { uploader.instance_variable_get(:@single_pipeline) }

    before do
      allow(pipeline).to receive(:with_token_retry).and_yield("xet_write_token_abc")
      allow(pipeline).to receive(:upload_xorb)
      allow(pipeline).to receive(:upload_shard)
    end

    it "returns hash with xet_hash and size" do
      result = uploader.upload(bucket_id, data, remote_path)

      expect(result).to eq({ xet_hash: file_hash.unpack1("H*"), size: data.bytesize })
    end

    it "fetches write token" do
      uploader.upload(bucket_id, data, remote_path)

      expect(token_manager).to have_received(:fetch_write_token).with(bucket_id)
    end

    it "calls upload_xorb with serialized data" do
      uploader.upload(bucket_id, data, remote_path)

      expect(pipeline).to have_received(:upload_xorb)
        .with(TestHelpers::CAS_URL, "xet_write_token_abc", xorb_hash, "xorb_serialized", cancel_token: nil)
    end

    it "calls upload_shard with shard data" do
      uploader.upload(bucket_id, data, remote_path)

      expect(pipeline).to have_received(:upload_shard)
        .with(TestHelpers::CAS_URL, "xet_write_token_abc", "shard_data", cancel_token: nil)
    end

    it "registers the file via api.batch" do
      uploader.upload(bucket_id, data, remote_path)

      file_hash_hex = file_hash.unpack1("H*")
      expect(api_client).to have_received(:batch).with(
        bucket_id, [hash_including(type: "addFile", path: remote_path, xetHash: file_hash_hex)],
        cancel_token: nil
      )
    end

    it "calls on_progress callback" do
      callback = double("callback")
      expect(callback).to receive(:call).with(remote_path, data.bytesize, data.bytesize)

      uploader.upload(bucket_id, data, remote_path, on_progress: callback)
    end

    it "logs debug messages" do
      expect(logger).to receive(:debug).at_least(:once)

      uploader.upload(bucket_id, data, remote_path)
    end

    context "with cancel_token" do
      it "raises CancelledError when token is pre-cancelled" do
        token = HuggingFaceStorage::CancelToken.new
        token.cancel!

        expect do
          uploader.upload(bucket_id, data, remote_path, cancel_token: token)
        end.to raise_error(HuggingFaceStorage::CancelledError)
      end
    end

    context "when error occurs" do
      it "propagates error from hasher#cdc_chunk" do
        allow(hasher).to receive(:cdc_chunk).and_raise(StandardError, "chunking failed")

        expect do
          uploader.upload(bucket_id, data, remote_path)
        end.to raise_error(StandardError, "chunking failed")
      end

      it "propagates error from serializer#serialize_xorb" do
        allow(serializer).to receive(:serialize_xorb).and_raise(StandardError, "serialization failed")

        expect do
          uploader.upload(bucket_id, data, remote_path)
        end.to raise_error(StandardError, "serialization failed")
      end
    end
  end
end
