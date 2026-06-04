# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::FileManager::Metadata do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:metadata) { described_class.new(api_client: api_client, bucket_id: bucket_id, logger: logger) }

  describe "#metadata" do
    it "fetches file info from API" do
      allow(api_client).to receive(:post).and_return([{ "path" => "f.txt", "size" => 100, "xet_hash" => "abc" }])
      result = metadata.metadata("f.txt")
      expect(result).to be_a(HuggingFaceStorage::FileInfo)
      expect(result.path).to eq("f.txt")
    end

    it "raises NotFoundError when file missing" do
      allow(api_client).to receive(:post).and_return(nil)
      expect { metadata.metadata("missing.txt") }.to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#exists?" do
    it "delegates to api_client.file_exists?" do
      allow(api_client).to receive(:file_exists?).with(bucket_id, "f.txt").and_return(true)
      expect(metadata.exists?("f.txt")).to be true
    end
  end
end
