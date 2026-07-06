# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "#download_repo_file" do
    it "downloads file directly" do
      stub_request(:get, "#{base}/org/repo/resolve/main/config.json")
        .to_return(status: 200, body: '{"config":true}',
                   headers: { "Content-Type" => "application/json" })

      result = client.download_repo_file("model", "org/repo", "config.json", revision: "main")
      expect(result).to eq('{"config":true}')
    end

    it "follows redirects" do
      stub_request(:get, "#{base}/org/repo/resolve/main/model.bin")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn/model.bin" })
      stub_request(:get, "#{base}/cdn/model.bin")
        .to_return(status: 200, body: "data")

      result = client.download_repo_file("model", "org/repo", "model.bin", revision: "main")
      expect(result).to eq("data")
    end

    it "raises on download failure" do
      stub_request(:get, "#{base}/org/repo/resolve/main/missing.txt")
        .to_return(status: 404, body: "Not Found")

      expect {
        client.download_repo_file("model", "org/repo", "missing.txt", revision: "main")
      }.to raise_error(HuggingFaceStorage::ApiError, /Download failed/)
    end

    it "uses datasets prefix for non-model repos" do
      stub_request(:get, "#{base}/datasets/org/data/resolve/main/data.csv")
        .to_return(status: 200, body: "csv,data")

      client.download_repo_file("dataset", "org/data", "data.csv", revision: "main")
      expect(WebMock).to have_requested(:get, "#{base}/datasets/org/data/resolve/main/data.csv")
    end
  end

  describe "#download_repo_file_streaming" do
    it "streams file content" do
      stub_request(:get, "#{base}/org/repo/resolve/main/data.bin")
        .to_return(status: 200, body: "streamed content")

      chunks = []
      client.download_repo_file_streaming("model", "org/repo", "data.bin", revision: "main") do |chunk|
        chunks << chunk
      end
      expect(chunks.join).to eq("streamed content")
    end
  end

  describe "#download_repo_file_streaming with redirect" do
    it "follows redirects during streaming" do
      stub_request(:get, "#{base}/org/repo/resolve/main/big.bin")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn/big.bin" })
      stub_request(:get, "#{base}/cdn/big.bin")
        .to_return(status: 200, body: "streamed data")

      chunks = []
      client.download_repo_file_streaming("model", "org/repo", "big.bin", revision: "main") do |chunk|
        chunks << chunk
      end
      expect(chunks.join).to eq("streamed data")
    end

    it "raises on non-2xx during streaming" do
      stub_request(:get, "#{base}/org/repo/resolve/main/bad.bin")
        .to_return(status: 403, body: "Forbidden")

      expect {
        client.download_repo_file_streaming("model", "org/repo", "bad.bin", revision: "main") { |_c| }
      }.to raise_error(HuggingFaceStorage::ApiError, /Download failed/)
    end

    it "raises on too many redirects" do
      stub_request(:get, /resolve|cdn\d*/)
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn1/loop" })
      stub_request(:get, "#{base}/cdn1/loop")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn2/loop" })
      stub_request(:get, "#{base}/cdn2/loop")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn3/loop" })
      stub_request(:get, "#{base}/cdn3/loop")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn4/loop" })
      stub_request(:get, "#{base}/cdn4/loop")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn5/loop" })
      stub_request(:get, "#{base}/cdn5/loop")
        .to_return(status: 302, headers: { "Location" => "#{base}/cdn6/loop" })

      expect {
        client.download_repo_file_streaming("model", "org/repo", "loop.bin", revision: "main") { |_c| }
      }.to raise_error(HuggingFaceStorage::ApiError, /Too many redirects/)
    end
  end
end
