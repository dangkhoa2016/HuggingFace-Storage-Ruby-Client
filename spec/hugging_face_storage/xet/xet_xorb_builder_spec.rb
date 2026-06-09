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

  describe "#serialize_xorb_from_ranges_concat" do
    let(:source_data) { "hello world test data".b }
    let(:chunk_hash) { ("\x01" * 32).b }

    context "with tuple format [source, offset, length, hash]" do
      it "serializes a single chunk" do
        chunk_info = [source_data, 0, 5, chunk_hash]
        result = dummy.serialize_xorb_from_ranges_concat([chunk_info])

        expect(result.bytesize).to eq(8 + 5)  # header + data
        expect(result[0]).to eq(0.chr)  # flags byte
        expect(result[8..]).to eq("hello".b)
      end

      it "serializes multiple chunks from same source" do
        chunk1 = [source_data, 0, 5, chunk_hash]
        chunk2 = [source_data, 6, 5, chunk_hash]
        result = dummy.serialize_xorb_from_ranges_concat([chunk1, chunk2])

        expect(result.bytesize).to eq(2 * (8 + 5))  # 2 headers + 2 data
        expect(result[0, 8]).to eq(HuggingFaceStorage::XetXorbBuilder::HEADER_TABLE[5])  # header 1
        expect(result[8..12]).to eq("hello".b)
        expect(result[13, 8]).to eq(HuggingFaceStorage::XetXorbBuilder::HEADER_TABLE[5])  # header 2
        expect(result[21..]).to eq("world".b)
      end

      it "serializes chunks from different sources" do
        source2 = "second buffer".b
        chunk1 = [source_data, 0, 5, chunk_hash]
        chunk2 = [source2, 0, 6, chunk_hash]
        result = dummy.serialize_xorb_from_ranges_concat([chunk1, chunk2])

        expect(result.bytesize).to eq(2 * 8 + 5 + 6)
        expect(result[8..12]).to eq("hello".b)
        expect(result[21..26]).to eq("second".b)
      end

      it "uses pre-computed header table for small sizes" do
        chunk_info = [source_data, 0, 5, chunk_hash]
        result = dummy.serialize_xorb_from_ranges_concat([chunk_info])

        expected_header = HuggingFaceStorage::XetXorbBuilder::HEADER_TABLE[5]
        expect(result[0, 8]).to eq(expected_header)
      end
    end

    context "with Hash format (legacy)" do
      it "serializes a single chunk" do
        chunk_info = { source: source_data, offset: 0, length: 5, hash: chunk_hash }
        result = dummy.serialize_xorb_from_ranges_concat([chunk_info])

        expect(result.bytesize).to eq(8 + 5)
        expect(result[0]).to eq(0.chr)
        expect(result[8..]).to eq("hello".b)
      end

      it "serializes multiple chunks" do
        chunk1 = { source: source_data, offset: 0, length: 5, hash: chunk_hash }
        chunk2 = { source: source_data, offset: 6, length: 5, hash: chunk_hash }
        result = dummy.serialize_xorb_from_ranges_concat([chunk1, chunk2])

        expect(result.bytesize).to eq(2 * (8 + 5))
        expect(result[8..12]).to eq("hello".b)
        expect(result[21..]).to eq("world".b)
      end
    end

    it "raises ArgumentError for chunks exceeding 24-bit limit" do
      big_source = "\x00".b * (HuggingFaceStorage::XetXorbBuilder::MAX_24BIT + 1)
      chunk_info = [big_source, 0, HuggingFaceStorage::XetXorbBuilder::MAX_24BIT + 1, chunk_hash]
      expect { dummy.serialize_xorb_from_ranges_concat([chunk_info]) }.to raise_error(ArgumentError, /chunk size/)
    end

    it "returns empty string for empty input" do
      result = dummy.serialize_xorb_from_ranges_concat([])
      expect(result).to eq("".b)
    end
  end
end
