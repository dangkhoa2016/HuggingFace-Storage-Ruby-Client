# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileDownloader do
  subject(:downloader) { described_class.new(api_client: api, logger: logger) }

  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:logger) { null_logger }
  let(:repo_type) { "model" }
  let(:repo_name) { "org/my-model" }
  let(:path) { "config.json" }
  let(:revision) { "main" }
  let(:cancel_token) { instance_double(HuggingFaceStorage::CancelToken) }
  let(:endpoint) { "https://huggingface.co" }

  before do
    allow(api).to receive(:endpoint).and_return(endpoint)
    allow(api).to receive(:stream_with_redirect)
    allow(api).to receive(:request_with_redirect)
  end

  describe "#download_repo_file_streaming" do
    it "streams file chunks from the resolve endpoint" do
      chunks = []
      allow(api).to receive(:stream_with_redirect).and_yield("chunk1").and_yield("chunk2")

      downloader.download_repo_file_streaming(repo_type, repo_name, path, revision: revision,
cancel_token: cancel_token) do |chunk|
        chunks << chunk
      end

      expect(api).to have_received(:stream_with_redirect).with(
        URI.parse("#{endpoint}/org/my-model/resolve/main/config.json"),
        hash_including(max_redirects: 5, cancel_token: cancel_token)
      )
    end

    it "yields data chunks" do
      chunks = []
      allow(api).to receive(:stream_with_redirect).and_yield("data1").and_yield("data2")

      downloader.download_repo_file_streaming(repo_type, repo_name, path, revision: revision) do |chunk|
        chunks << chunk
      end

      expect(chunks).to eq(%w[data1 data2])
    end

    context "with dataset repo type" do
      let(:repo_type) { "dataset" }

      it "builds URL with datasets prefix" do
        downloader.download_repo_file_streaming(repo_type, repo_name, path, revision: revision) { |_| nil }

        expect(api).to have_received(:stream_with_redirect).with(
          URI.parse("#{endpoint}/datasets/org/my-model/resolve/main/config.json"),
          anything
        )
      end
    end

    context "without revision" do
      let(:revision) { nil }

      it "builds URL without revision segment" do
        downloader.download_repo_file_streaming(repo_type, repo_name, path, revision: revision) { |_| nil }

        expect(api).to have_received(:stream_with_redirect).with(
          URI.parse("#{endpoint}/org/my-model/resolve/config.json"),
          anything
        )
      end
    end
  end

  describe "#download_repo_file" do
    let(:response) { instance_double(Net::HTTPResponse) }
    let(:body) { instance_double(String) }

    before do
      allow(body).to receive(:b).and_return("file content".b)
      allow(response).to receive(:body).and_return(body)
      allow(api).to receive(:request_with_redirect).and_return(response)
    end

    it "returns file contents as binary string" do
      result = downloader.download_repo_file(repo_type, repo_name, path, revision: revision, cancel_token: cancel_token)

      expect(api).to have_received(:request_with_redirect).with(
        URI.parse("#{endpoint}/org/my-model/resolve/main/config.json"),
        hash_including(cancel_token: cancel_token)
      )
      expect(result).to eq("file content".b)
    end

    context "without cancel_token" do
      it "downloads without cancel token" do
        downloader.download_repo_file(repo_type, repo_name, path, revision: revision)

        expect(api).to have_received(:request_with_redirect).with(
          URI.parse("#{endpoint}/org/my-model/resolve/main/config.json"),
          hash_including(cancel_token: nil)
        )
      end
    end
  end
end
