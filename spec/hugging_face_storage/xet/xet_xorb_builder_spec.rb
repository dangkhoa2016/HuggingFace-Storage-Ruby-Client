# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetXorbBuilder do
  let(:dummy) do
    Class.new do
      include HuggingFaceStorage::XetXorbBuilder

      attr_accessor :hasher
    end.new.tap { |d| d.hasher = instance_double(HuggingFaceStorage::XetHasher) }
  end

  describe "#serialize_xorb" do
    it "returns empty binary for empty chunks" do
      expect(dummy.serialize_xorb([])).to eq("".b)
    end

    it "serializes a single chunk with header" do
      data = "hello".b
      result = dummy.serialize_xorb([data])
      expect(result.bytesize).to eq(2 + 3 + 3 + 5)
      expect(result[0]).to eq(0.chr)
      expect(result[4]).to eq(0.chr)
      expect(result[8..]).to eq(data)
    end

    it "raises ArgumentError for chunks exceeding 24-bit limit" do
      big = "\x00".b * (HuggingFaceStorage::XetXorbBuilder::MAX_24BIT + 1)
      expect { dummy.serialize_xorb([big]) }.to raise_error(ArgumentError, /chunk size/)
    end
  end

  describe "#pack_xorbs" do
    let(:chunk_a) { { data: "a" * 100, hash: ("\x01" * 32).b, length: 100 } }
    let(:chunk_b) { { data: "b" * 100, hash: ("\x02" * 32).b, length: 100 } }

    it "returns empty array for no chunks" do
      expect(dummy.pack_xorbs([])).to eq([])
    end

    it "packs chunks into a single xorb" do
      allow(dummy.hasher).to receive(:compute_xorb_hash).and_return(("\xab" * 32).b)

      xorbs = dummy.pack_xorbs([chunk_a, chunk_b])

      expect(xorbs.size).to eq(1)
      expect(xorbs[0][:hash]).to eq(("\xab" * 32).b)
      expect(xorbs[0][:chunks].size).to eq(2)
    end

    it "splits into multiple xorbs when exceeding max chunks per xorb" do
      many_chunks = (HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS + 1).times.map do |i|
        { data: "x", hash: ("\x03" * 32).b, length: 1 }
      end
      allow(dummy.hasher).to receive(:compute_xorb_hash).and_return(("\xab" * 32).b)
      xorbs = dummy.pack_xorbs(many_chunks)

      expect(xorbs.size).to eq(2)
      expect(xorbs[0][:chunks].size).to eq(HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS)
      expect(xorbs[1][:chunks].size).to eq(1)
    end
  end

  describe "#finalize_xorb" do
    it "serializes chunks and computes hash" do
      chunks = [{ data: "abc", hash: ("\x05" * 32).b, length: 3 }]
      allow(dummy.hasher).to receive(:compute_xorb_hash).and_return(("\xcd" * 32).b)

      result = dummy.finalize_xorb(chunks)

      expect(result[:hash]).to eq(("\xcd" * 32).b)
      expect(result[:chunks]).to eq(chunks)
      expect(result[:data]).to be_a(String)
    end
  end
end
