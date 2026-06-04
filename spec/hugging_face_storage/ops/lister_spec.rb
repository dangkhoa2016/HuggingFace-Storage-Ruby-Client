# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::FileManager::Lister do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:lister) { described_class.new(api_client: api_client, bucket_id: bucket_id, logger: logger) }

  describe "#list_all" do
    it "logs prefix and batch_size, then returns paginated results" do
      allow(api_client).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "a.txt", "size" => 10 }
      ])

      results = lister.list_all(prefix: "data/", batch_size: 500)

      expect(logger).to have_received(:info).with(/Listing all files: prefix=data\/ batch_size=500/)
      expect(api_client).to have_received(:get_paginated).with(
        "/api/buckets/test-bucket/tree/data/",
        params: { recursive: "true" },
        cancel_token: nil
      )
      expect(results.size).to eq(1)
    end

    it "logs without prefix when prefix is nil" do
      allow(api_client).to receive(:get_paginated).and_return([])

      lister.list_all(prefix: nil)

      expect(logger).to have_received(:info).with(/prefix=root/)
    end
  end

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

  describe "#list_entries" do
    it "returns both files and directories" do
      allow(api_client).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "f.txt", "size" => 100, "xet_hash" => "abc", "mtime" => "2024-01-01" },
        { "type" => "directory", "path" => "sub", "uploadedAt" => "2024-01-02" }
      ])
      results = lister.list_entries(prefix: "", recursive: false)
      expect(results.size).to eq(2)
      expect(results).to all(be_a(HuggingFaceStorage::EntryInfo))
      expect(results.map(&:type)).to contain_exactly("file", "directory")
    end

    it "includes directory upload time as mtime" do
      allow(api_client).to receive(:get_paginated).and_return([
        { "type" => "directory", "path" => "models", "uploadedAt" => "2024-01-15" }
      ])
      results = lister.list_entries
      expect(results.first.mtime).to eq("2024-01-15")
    end
  end
end
