# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::TreeLoader do
  describe ".load" do
    it "loads tree from Array of entries" do
      tree = [{ "path" => "a.txt", "size" => 100, "xetHash" => "h1" }]
      result = described_class.load(tree)
      expect(result.size).to eq(1)
      expect(result[0]["path"]).to eq("a.txt")
    end

    it "raises ArgumentError for invalid type" do
      expect { described_class.load(42) }
        .to raise_error(ArgumentError, /tree must be a file path/)
    end

    it "raises Error when loaded entries is not an array" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "tree.json")
        File.write(path, "{}")
        expect { described_class.load(path) }
          .to raise_error(HuggingFaceStorage::Error, /Tree entries must be an array/)
      end
    end

    it "loads tree from JSON file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "tree.json")
        File.write(path, JSON.generate([{ "path" => "f.txt" }]))
        result = described_class.load(path)
        expect(result.size).to eq(1)
      end
    end

    it "raises Error when file does not exist" do
      expect { described_class.load("/nonexistent/tree.json") }
        .to raise_error(HuggingFaceStorage::Error, /Tree file not found/)
    end
  end

  describe ".normalize_entry" do
    it "passes through hash entries with string 'path' key" do
      entry = { "path" => "f.txt", "xetHash" => "h1" }
      expect(described_class.normalize_entry(entry)).to eq(entry)
    end

    it "converts symbol-keyed entries to string-keyed format" do
      entry = { path: "f.txt", xet_hash: "h1", size: 100 }
      result = described_class.normalize_entry(entry)
      expect(result).to eq("path" => "f.txt", "xetHash" => "h1", "size" => 100, "type" => "file")
    end

    it "converts non-Hash entries (e.g. strings) to file entry format" do
      entry = "some/path.txt"
      result = described_class.normalize_entry(entry)
      expect(result).to eq("path" => "some/path.txt", "xetHash" => nil, "size" => nil, "type" => "file")
    end
  end
end
