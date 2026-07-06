# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::MetadataCache do
  subject(:cache) { described_class.new }

  describe "#fetch" do
    it "returns the cached value if key exists" do
      cache.store("key", "value")
      expect(cache.fetch("key", "new_value")).to eq("value")
    end

    it "computes and stores the value if key is missing" do
      result = cache.fetch("key", "computed")
      expect(result).to eq("computed")
      expect(cache.fetch("key", "different")).to eq("computed")
    end

    it "is thread-safe" do
      threads = Array.new(10) do |i|
        Thread.new { cache.fetch("shared") { i } }
      end
      results = threads.map(&:value)
      expect(results.uniq.size).to eq(1)
    end
  end

  describe "#store" do
    it "stores a value for a key" do
      cache.store("a", 1)
      expect(cache.fetch("a", 2)).to eq(1)
    end

    it "overwrites existing values" do
      cache.store("a", 1)
      cache.store("a", 2)
      expect(cache.fetch("a", 3)).to eq(2)
    end
  end

  describe "#invalidate" do
    it "removes a cached value" do
      cache.store("key", "value")
      cache.invalidate("key")
      expect(cache.fetch("key", "new")).to eq("new")
    end
  end

  describe "#clear" do
    it "removes all cached values" do
      cache.store("a", 1)
      cache.store("b", 2)
      cache.clear
      expect(cache.fetch("a", nil)).to be_nil
      expect(cache.fetch("b", nil)).to be_nil
    end
  end
end
