# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CdcChunker do
  describe "constants" do
    it "has correct chunk sizes" do
      expect(described_class::TARGET_CHUNK).to eq(65_536)
      expect(described_class::MIN_CHUNK).to eq(8_192)
      expect(described_class::MAX_CHUNK).to eq(131_072)
    end

    it "has correct mask and hash window" do
      expect(described_class::MASK).to eq(0xFFFF_0000_0000_0000)
      expect(described_class::HASH_WINDOW).to eq(64)
    end
  end

  describe ".gearhash_step" do
    it "returns a 64-bit value" do
      result = described_class.gearhash_step(0, 65)
      expect(result).to be_a(Integer)
      expect(result).to be <= 0xFFFF_FFFF_FFFF_FFFF
    end

    it "is deterministic" do
      a = described_class.gearhash_step(0, 65)
      b = described_class.gearhash_step(0, 65)
      expect(a).to eq(b)
    end
  end

  describe "included in XetHasher" do
    it "exposes constants via XetHasher" do
      expect(HuggingFaceStorage::XetHasher::TARGET_CHUNK).to eq(described_class::TARGET_CHUNK)
      expect(HuggingFaceStorage::XetHasher::MIN_CHUNK).to eq(described_class::MIN_CHUNK)
      expect(HuggingFaceStorage::XetHasher::MAX_CHUNK).to eq(described_class::MAX_CHUNK)
      expect(HuggingFaceStorage::XetHasher::MASK).to eq(described_class::MASK)
    end

    it "exposes gearhash_step via XetHasher" do
      expect(HuggingFaceStorage::XetHasher.gearhash_step(0, 65))
        .to eq(described_class.gearhash_step(0, 65))
    end

    it "provides cdc_chunk instance methods" do
      hasher = HuggingFaceStorage::XetHasher.new
      expect(hasher).to respond_to(:cdc_chunk)
      expect(hasher).to respond_to(:cdc_chunk_ruby)
    end
  end
end
