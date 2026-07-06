# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::RepoFileCopier do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:download_repo_file).and_return("small content".b)
      allow(a).to receive(:download_repo_file_streaming)
    end
  end
  let(:xet_uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_batch).and_return([])
      allow(x).to receive(:stream_download_and_upload).and_return({ remote_path: "large.bin", xet_hash: "abc123",
size: 200_000 })
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }

  subject(:copier) do
    described_class.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger)
  end

  describe "#copy" do
    it "returns zero when pending_downloads empty" do
      result = copier.copy([])
      expect(result[:downloaded]).to eq(0)
    end

    it "downloads small files via batch upload" do
      pending = [
        { source_type: "model", source_repo: "org/repo", source_path: "small.txt", size: 50,
destination: "dest/small.txt" }
      ]
      result = copier.copy(pending)
      expect(result[:downloaded]).to eq(1)
      expect(api).to have_received(:download_repo_file).once
      expect(xet_uploader).to have_received(:upload_batch).once
    end

    it "downloads large files via streaming" do
      allow(api).to receive(:download_repo_file_streaming)

      allow(xet_uploader).to receive(:stream_download_and_upload) do |_bucket_id, _remote_path, **, &block|
        block.call(->(c) {})
        { remote_path: "large.bin", xet_hash: "abc", size: 200_000 }
      end

      pending = [
        { source_type: "dataset", source_repo: "org/data", source_path: "large.bin", revision: "main", size: 200_000,
destination: "dest/large.bin" }
      ]
      result = copier.copy(pending)
      expect(result[:downloaded]).to eq(1)
      expect(xet_uploader).to have_received(:stream_download_and_upload).once
    end

    it "calls on_progress callback" do
      progress_calls = []
      pending = [
        { source_type: "model", source_repo: "org/repo", source_path: "a.txt", size: 50, destination: "dest/a.txt" }
      ]
      copier.copy(pending, on_progress: ->(progress) { progress_calls << progress })
      expect(progress_calls.size).to eq(1)
    end

    it "calls on_large_complete for large files" do
      allow(api).to receive(:download_repo_file_streaming)

      allow(xet_uploader).to receive(:stream_download_and_upload) do |_bucket_id, _remote_path, **, &block|
        block.call(->(c) {})
        { remote_path: "large.bin", xet_hash: "abc", size: 200_000 }
      end

      large_calls = []
      pending = [
        { source_type: "model", source_repo: "org/repo", source_path: "large.bin", size: 200_000,
destination: "dest/large.bin" }
      ]
      copier.copy(pending, on_large_complete: ->(op) { large_calls << op })
      expect(large_calls.size).to eq(1)
      expect(large_calls[0][:type]).to eq("addFile")
    end

    it "checks cancel_token before each operation" do
      token = HuggingFaceStorage::CancelToken.new
      pending = [
        { source_type: "model", source_repo: "org/repo", source_path: "a.txt", size: 50, destination: "dest/a.txt" }
      ]
      result = copier.copy(pending, cancel_token: token)
      expect(result[:downloaded]).to eq(1)
    end
  end
end
