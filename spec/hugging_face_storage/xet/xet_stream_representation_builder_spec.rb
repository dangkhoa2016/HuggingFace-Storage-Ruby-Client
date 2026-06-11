# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetStreamRepresentationBuilder do
  subject(:builder) { described_class.new(hasher) }

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:first_chunk_hash) { "hash1" }
  let(:second_chunk_hash) { "hash2" }
  let(:verification_hash) { "verify123" }

  before do
    allow(hasher).to receive(:compute_verification_hash).and_return(verification_hash)
  end

  it "returns empty ranges from finalize" do
    expect(builder.finalize).to eq([])
  end

  describe "#start_xorb, #add_chunk, #finalize_xorb" do
    it "builds a single xorb range" do
      builder.start_xorb
      builder.add_chunk(first_chunk_hash, 100)
      builder.add_chunk(second_chunk_hash, 200)
      builder.finalize_xorb("xorb1")

      ranges = builder.finalize
      expect(ranges.size).to eq(1)

      range = ranges.first
      expect(range[:xorb_hash]).to eq("xorb1")
      expect(range[:index_start]).to eq(0)
      expect(range[:index_end]).to eq(2)
      expect(range[:length]).to eq(300)
      expect(range[:range_hash]).to eq(verification_hash)
      expect(hasher).to have_received(:compute_verification_hash).with([first_chunk_hash, second_chunk_hash])
    end

    it "builds multiple xorb ranges" do
      builder.start_xorb
      builder.add_chunk(first_chunk_hash, 100)
      builder.finalize_xorb("xorb1")

      builder.start_xorb
      builder.add_chunk(second_chunk_hash, 200)
      builder.finalize_xorb("xorb2")

      ranges = builder.finalize
      expect(ranges.size).to eq(2)
      expect(ranges[0][:xorb_hash]).to eq("xorb1")
      expect(ranges[0][:length]).to eq(100)
      expect(ranges[1][:xorb_hash]).to eq("xorb2")
      expect(ranges[1][:length]).to eq(200)
    end
  end

  describe "#finalize" do
    it "auto-finalizes the current xorb if chunks remain" do
      builder.start_xorb
      builder.add_chunk(first_chunk_hash, 100)

      ranges = builder.finalize
      expect(ranges.size).to eq(1)
      expect(ranges.first[:xorb_hash]).to be_nil
    end

    it "does not produce a range for an empty xorb" do
      builder.start_xorb
      builder.finalize_xorb("xorb1")
      builder.start_xorb
      builder.add_chunk(first_chunk_hash, 100)
      builder.finalize_xorb("xorb2")

      ranges = builder.finalize
      expect(ranges.size).to eq(1)
      expect(ranges.first[:xorb_hash]).to eq("xorb2")
    end
  end
end
