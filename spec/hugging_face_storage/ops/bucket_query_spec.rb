# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::BucketQuery do
  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  describe ".query_paths" do
    it "posts paths-info request" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", body: { paths: ["a.txt"] })
        .and_return([{ "path" => "a.txt" }])

      result = described_class.query_paths(api, bucket_id, ["a.txt"])
      expect(result).to be_an(Array)
    end
  end

  describe ".fetch_file_info" do
    it "returns file info hash" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt", "xetHash" => "h1", "size" => 100 }])

      result = described_class.fetch_file_info(api, bucket_id, "a.txt")
      expect(result[:path]).to eq("a.txt")
      expect(result[:xet_hash]).to eq("h1")
      expect(result[:size]).to eq(100)
    end

    it "raises NotFoundError for missing file" do
      allow(api).to receive(:post).and_return([])
      expect { described_class.fetch_file_info(api, bucket_id, "missing.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe ".file_exists?" do
    it "returns true when file exists" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt" }])

      expect(described_class.file_exists?(api, bucket_id, "a.txt")).to be true
    end

    it "returns false when results are empty" do
      allow(api).to receive(:post).and_return([])

      expect(described_class.file_exists?(api, bucket_id, "missing.txt")).to be false
    end

    it "returns false when results are nil" do
      allow(api).to receive(:post).and_return(nil)

      expect(described_class.file_exists?(api, bucket_id, "missing.txt")).to be false
    end

    it "returns false on NotFoundError" do
      allow(api).to receive(:post).and_raise(HuggingFaceStorage::NotFoundError, "not found")

      expect(described_class.file_exists?(api, bucket_id, "missing.txt")).to be false
    end
  end

  describe ".ensure_file!" do
    it "raises NotFoundError when file not found" do
      allow(api).to receive(:post).and_return([])
      expect { described_class.ensure_file!(api, bucket_id, "missing.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end

    it "raises Error when path is a directory" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "mydir", "type" => "directory" }])

      expect { described_class.ensure_file!(api, bucket_id, "mydir") }
        .to raise_error(HuggingFaceStorage::Error, /directory/)
    end
  end

  describe ".ensure_files!" do
    it "returns normally when all files exist" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt", "type" => "file" }, { "path" => "b.txt", "type" => "file" }])

      expect { described_class.ensure_files!(api, bucket_id, ["a.txt", "b.txt"]) }.not_to raise_error
    end

    it "raises Error when a path is a directory" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt", "type" => "file" }, { "path" => "mydir", "type" => "directory" }])

      expect { described_class.ensure_files!(api, bucket_id, ["a.txt", "mydir"]) }
        .to raise_error(HuggingFaceStorage::Error, /directory/)
    end

    it "raises NotFoundError when a file is missing" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt", "type" => "file" }])

      expect { described_class.ensure_files!(api, bucket_id, ["a.txt", "missing.txt"]) }
        .to raise_error(HuggingFaceStorage::NotFoundError, /missing/)
    end

    it "delegates to ensure_file! for single path" do
      allow(api).to receive(:post)
        .and_return([{ "path" => "a.txt", "type" => "file" }])

      expect { described_class.ensure_files!(api, bucket_id, ["a.txt"]) }.not_to raise_error
    end
  end
end
