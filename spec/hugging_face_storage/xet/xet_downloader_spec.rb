# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetDownloader do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:endpoint) { "https://huggingface.co" }
  let(:bucket_id) { "test-bucket" }
  let(:remote_path) { "data/file.txt" }

  subject(:downloader) do
    described_class.new(
      api_client: api_client,
      token_manager: token_manager,
      endpoint: endpoint,
      logger: null_logger
    )
  end

  describe "#initialize" do
    it "creates a XetDownloader with the given dependencies" do
      expect(downloader).to be_a(described_class)
      expect(downloader).to respond_to(:download_file)
      expect(downloader).to respond_to(:download_data)
      expect(downloader).to respond_to(:download_data_streaming)
    end
  end

  describe "#download_file" do
    it "downloads a file to the specified local path" do
      allow(api_client).to receive(:stream_with_redirect) do |uri, **kwargs, &block|
        block.call("hello ".b)
        block.call("world".b)
      end

      Dir.mktmpdir do |dir|
        local = File.join(dir, "output.txt")
        downloader.download_file(bucket_id, remote_path, local)
        expect(File.read(local, mode: "rb")).to eq("hello world")
      end
    end

    it "raises on network error" do
      allow(api_client).to receive(:stream_with_redirect).and_raise(Net::ReadTimeout, "execution expired")

      Dir.mktmpdir do |dir|
        local = File.join(dir, "output.txt")
        expect { downloader.download_file(bucket_id, remote_path, local) }
          .to raise_error(Net::ReadTimeout)
      end
    end
  end

  describe "#download_data_streaming" do
    it "yields data blocks to the caller" do
      chunks = []
      allow(api_client).to receive(:stream_with_redirect) do |uri, **kwargs, &block|
        block.call("chunk1".b)
        block.call("chunk2".b)
      end

      downloader.download_data_streaming(bucket_id, remote_path) { |chunk| chunks << chunk }
      expect(chunks).to eq(["chunk1".b, "chunk2".b])
    end
  end
end
