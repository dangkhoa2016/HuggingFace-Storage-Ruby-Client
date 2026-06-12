# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetUploader do
  subject(:uploader) do
    described_class.new(
      hasher: hasher, serializer: serializer, token_manager: token_manager,
      api_client: api_client, endpoint: endpoint, config: config,
      logger: logger, transport: transport
    )
  end

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:serializer) { instance_double(HuggingFaceStorage::XetSerializer) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient, batch: nil) }
  let(:endpoint) { "https://huggingface.co" }
  let(:config) { instance_double(HuggingFaceStorage::Configuration) }
  let(:logger) { null_logger }
  let(:transport) { nil }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:remote_path) { "remote/test.bin" }
  let(:data_uploader) { instance_double(HuggingFaceStorage::XetDataUploader) }

  describe "#initialize" do
    context "when no transport given" do
      it "creates HttpPool and Retryable" do
        http_pool = instance_double(HuggingFaceStorage::HttpPool)
        retryable = instance_double(HuggingFaceStorage::Retryable)
        allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
        allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
        allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

        uploader

        expect(HuggingFaceStorage::HttpPool).to have_received(:new).with(config: config, logger: logger)
        expect(HuggingFaceStorage::Retryable).to have_received(:new).with(logger: logger)
      end
    end

    context "when transport is provided" do
      let(:transport) { instance_double(HuggingFaceStorage::HTTPTransport) }

      it "does not create HttpPool or Retryable" do
        http_pool = instance_double(HuggingFaceStorage::HttpPool)
        retryable = instance_double(HuggingFaceStorage::Retryable)
        allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
        allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
        allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

        uploader

        expect(HuggingFaceStorage::HttpPool).not_to have_received(:new)
        expect(HuggingFaceStorage::Retryable).not_to have_received(:new)
      end
    end
  end

  describe "#upload_file_to_path" do
    let(:local_path) { "/tmp/test.bin" }

    before do
      http_pool = instance_double(HuggingFaceStorage::HttpPool)
      retryable = instance_double(HuggingFaceStorage::Retryable)
      allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
      allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
      allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

      allow(File).to receive(:size).with(local_path).and_return(100)
      allow(config).to receive(:stream_threshold).and_return(10 * 1024 * 1024)
    end

    it "returns success hash on completion" do
      file_data = "test data"
      allow(File).to receive(:binread).with(local_path).and_return(file_data)

      expected = { xet_hash: "abc", size: file_data.bytesize }
      allow(data_uploader).to receive(:upload)
        .with(bucket_id, file_data, remote_path, on_progress: nil, cancel_token: nil)
        .and_return(expected)

      result = uploader.upload_file_to_path(bucket_id, local_path, remote_path)
      expect(result).to eq(expected)
    end

    it "raises typed error on API failure" do
      file_data = "test data"
      allow(File).to receive(:binread).with(local_path).and_return(file_data)

      allow(data_uploader).to receive(:upload).and_raise(
        HuggingFaceStorage::ApiError.new(status: 500, message: "Upload failed")
      )

      expect do
        uploader.upload_file_to_path(bucket_id, local_path, remote_path)
      end.to raise_error(HuggingFaceStorage::ApiError, /Upload failed/)
    end
  end

  describe "#stream_download_and_upload" do
    let(:stream_processor) { instance_double(HuggingFaceStorage::XetStreamProcessor) }

    before do
      http_pool = instance_double(HuggingFaceStorage::HttpPool)
      retryable = instance_double(HuggingFaceStorage::Retryable)
      allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
      allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
      allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

      write_info = { endpoint: TestHelpers::CAS_URL, token: "stream_token" }
      allow(token_manager).to receive(:fetch_write_token).with(bucket_id).and_return(write_info)
      allow(HuggingFaceStorage::XetStreamProcessor).to receive(:new)
        .with(hasher: hasher, serializer: serializer, logger: logger, config: config, transport: transport)
        .and_return(stream_processor)
    end

    it "processes chunks from StringIO and returns upload result" do
      stream_result = { xet_hash: "def", size: 15, remote_path: remote_path }
      chunks = []
      allow(stream_processor).to receive(:stream_upload) do |_path, cas_url:, token:, cancel_token:, &block|
        expect(cas_url).to eq(TestHelpers::CAS_URL)
        expect(token).to eq("stream_token")
        write_chunk = proc { |c| chunks << c }
        block.call(write_chunk)
        stream_result
      end

      result = uploader.stream_download_and_upload(bucket_id, remote_path) do |&write_chunk|
        write_chunk.call("chunk_a")
        write_chunk.call("chunk_b")
      end

      expect(chunks).to contain_exactly("chunk_a", "chunk_b")
      expect(result).to eq(stream_result)
      expect(api_client).to have_received(:batch).with(
        bucket_id,
        [{ type: HuggingFaceStorage::ApiOperations::ADD_FILE, path: remote_path, xetHash: "def",
mtime: kind_of(Integer) }],
        cancel_token: nil
      )
    end
  end

  describe "#report_batch_progress" do
    it "invokes the on_progress callback with index, path, and size" do
      http_pool = instance_double(HuggingFaceStorage::HttpPool)
      retryable = instance_double(HuggingFaceStorage::Retryable)
      allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
      allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
      allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

      received = []
      on_progress = proc { |idx, path, size| received << [idx, path, size] }
      entry = { remote_path: "out/file.bin", size: 1024 }
      uploader.send(:report_batch_progress, entry, on_progress, 2, 5)
      expect(received).to eq([[2, "out/file.bin", 1024]])
    end

    it "does not raise when on_progress is nil" do
      http_pool = instance_double(HuggingFaceStorage::HttpPool)
      retryable = instance_double(HuggingFaceStorage::Retryable)
      allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
      allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
      allow(HuggingFaceStorage::XetDataUploader).to receive(:new).and_return(data_uploader)

      entry = { remote_path: "out/file.bin", size: 1024 }
      expect { uploader.send(:report_batch_progress, entry, nil, 0, 1) }.not_to raise_error
    end
  end
end
