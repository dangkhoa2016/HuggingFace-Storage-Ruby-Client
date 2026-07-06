# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::FileManager::Lister do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:lister) { described_class.new(api_client: api_client, bucket_id: bucket_id, logger: logger) }

  describe "#list" do
    it "fetches paginated tree and returns FileInfo objects" do
      allow(api_client).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "f.txt", "size" => 100, "xet_hash" => "abc", "mtime" => "2024-01-01" }
      ])
      results = lister.list(prefix: "dir", recursive: true)
      expect(results).to all(be_a(HuggingFaceStorage::FileInfo))
      expect(results.size).to eq(1)
    end

    it "filters out directory entries" do
      allow(api_client).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "f.txt", "size" => 100, "xet_hash" => "abc", "mtime" => "2024-01-01" },
        { "type" => "directory", "path" => "sub", "size" => 0 }
      ])
      results = lister.list(prefix: "")
      expect(results.size).to eq(1)
    end
  end
end
