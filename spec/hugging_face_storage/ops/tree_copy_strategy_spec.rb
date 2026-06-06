# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::CrossRepoCopyService::TreeCopyStrategy do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:file_manager) { instance_double(HuggingFaceStorage::FileManager) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:strategy) do
    described_class.new(api_client: api_client, file_manager: file_manager, bucket_id: bucket_id, logger: logger)
  end

  describe "#call" do
    let(:tree) do
      [
        { "type" => "file", "path" => "dir/file1.txt", "size" => 100, "xetHash" => "abc123" },
        { "type" => "file", "path" => "dir/file2.txt", "size" => 200, "xetHash" => "def456" },
        { "type" => "directory", "path" => "dir/sub", "size" => 0 },
      ]
    end

    it "copies files with prefix filtering and destination mapping" do
      allow(HuggingFaceStorage::TreeLoader).to receive(:load).and_return(tree)
      allow(HuggingFaceStorage::BucketQuery).to receive(:reject_existing!).and_return(0)
      expect(file_manager).to receive(:copy_from).with(
        source_type: "model", source_repo: "user/repo",
        files: contain_exactly(
          hash_including(destination: "dst/file1.txt", xet_hash: "abc123"),
          hash_including(destination: "dst/file2.txt", xet_hash: "def456")
        ),
        cancel_token: nil
      )
      result = strategy.call(tree: tree, source_type: "model", source_repo: "user/repo",
                              source_prefix: "dir", destination_prefix: "dst")
      expect(result[:files_copied]).to eq(2)
      expect(result[:total_size]).to eq(300)
    end

    it "raises Error when no matching files after filtering" do
      allow(HuggingFaceStorage::TreeLoader).to receive(:load).and_return(tree)
      expect {
        strategy.call(tree: tree, source_type: "model", source_repo: "user/repo",
                               source_prefix: "nonexistent")
      }
        .to raise_error(HuggingFaceStorage::Error, /No matching files/)
    end

    it "returns empty result when all files exist and overwrite is false" do
      allow(HuggingFaceStorage::TreeLoader).to receive(:load).and_return(tree)
      expect(HuggingFaceStorage::BucketQuery).to receive(:reject_existing!) do |_, _, files, _|
        files.clear
        2
      end
      expect(file_manager).not_to receive(:copy_from)
      result = strategy.call(tree: tree, source_type: "model", source_repo: "user/repo",
                              source_prefix: "dir")
      expect(result[:files_copied]).to eq(0)
    end
  end
end
