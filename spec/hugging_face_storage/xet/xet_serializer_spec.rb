# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetSerializer do
  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:serializer) { described_class.new(hasher) }

  # ── Constants ──

  describe "constants" do
    it "has correct shard constants" do
      expect(described_class::SHARD_HEADER_SIZE).to eq(48)
      expect(described_class::SHARD_FOOTER_SIZE).to eq(200)
    end
  end

  # ── Xorb Serialization ──

  describe "#serialize_xorb" do
    it "serializes single chunk with correct header" do
      chunk = "hello".b
      serialized = serializer.serialize_xorb([chunk])
      expect(serialized.encoding).to eq(Encoding::ASCII_8BIT)
      expect(serialized.bytesize).to eq(8 + chunk.bytesize)
      expect(serialized.getbyte(0)).to eq(0)
      expect(serialized.getbyte(1)).to eq(5)
      expect(serialized.getbyte(2)).to eq(0)
      expect(serialized.getbyte(3)).to eq(0)
      expect(serialized.getbyte(4)).to eq(0)
      expect(serialized.getbyte(5)).to eq(5)
      expect(serialized.byteslice(8, 5)).to eq("hello")
    end

    it "serializes multiple chunks" do
      chunks = ["aaa".b, "bbb".b]
      serialized = serializer.serialize_xorb(chunks)
      expect(serialized.bytesize).to eq(2 * 8 + 3 + 3)
    end

    it "handles large chunk size encoding" do
      chunk = ("x" * 70_000).b
      serialized = serializer.serialize_xorb([chunk])
      expect(serialized.getbyte(1)).to eq(0x70)
      expect(serialized.getbyte(2)).to eq(0x11)
      expect(serialized.getbyte(3)).to eq(0x01)
    end
  end

  # ── Pack xorbs ──

  describe "#pack_xorbs" do
    it "packs small chunks into single xorb" do
      chunks = 3.times.map do |i|
        data = "chunk#{i}".b
        { data: data, hash: hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data), length: data.bytesize }
      end
      xorbs = serializer.pack_xorbs(chunks)
      expect(xorbs.size).to eq(1)
      expect(xorbs[0][:chunks].size).to eq(3)
      expect(xorbs[0][:data].bytesize).to be > 0
      expect(xorbs[0][:hash].bytesize).to eq(32)
    end

    it "splits when XORB_MAX_CHUNKS exceeded" do
      chunks = (HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS + 10).times.map do |i|
        data = "c#{i}".b
        { data: data, hash: hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data), length: data.bytesize }
      end
      xorbs = serializer.pack_xorbs(chunks)
      expect(xorbs.size).to eq(2)
      expect(xorbs[0][:chunks].size).to eq(HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS)
      expect(xorbs[1][:chunks].size).to eq(10)
    end
  end

  # ── Build Representation ──

  describe "#build_representation" do
    it "returns empty array for zero chunks" do
      result = serializer.build_representation(0, 0, [], [])
      expect(result).to eq([])
    end

    it "builds representation for single file" do
      data1 = "hello".b
      hash1 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data1)
      chunks = [{ data: data1, hash: hash1, length: data1.bytesize }]
      xorbs = serializer.pack_xorbs(chunks)
      result = serializer.build_representation(0, 1, chunks, xorbs)
      expect(result.size).to eq(1)
      expect(result[0][:xorb_hash]).to eq(xorbs[0][:hash])
      expect(result[0][:index_start]).to eq(0)
      expect(result[0][:index_end]).to eq(1)
      expect(result[0][:length]).to eq(data1.bytesize)
      expect(result[0][:range_hash].bytesize).to eq(32)
    end

    it "builds representations for multiple files" do
      chunks = []
      3.times do |i|
        data = "file#{i}data".b
        hash = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data)
        chunks << { data: data, hash: hash, length: data.bytesize }
      end
      xorbs = serializer.pack_xorbs(chunks)
      r1 = serializer.build_representation(0, 1, chunks, xorbs)
      r2 = serializer.build_representation(1, 1, chunks, xorbs)
      r3 = serializer.build_representation(2, 1, chunks, xorbs)
      expect(r1.size).to eq(1)
      expect(r2.size).to eq(1)
      expect(r3.size).to eq(1)
    end

    it "merges consecutive chunks from the same xorb" do
      hash1 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, "a".b * 100)
      hash2 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, "a".b * 100)
      hash3 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, "a".b * 100)
      chunks = [
        { data: "a".b * 100, hash: hash1, length: 100 },
        { data: "a".b * 100, hash: hash2, length: 100 },
        { data: "a".b * 100, hash: hash3, length: 100 }
      ]
      xorbs = serializer.pack_xorbs(chunks)
      result = serializer.build_representation(0, 3, chunks, xorbs)
      expect(result.size).to eq(1)
      expect(result[0][:index_start]).to eq(0)
      expect(result[0][:index_end]).to eq(3)
    end
  end

  # ── Shard Building ──

  describe "#build_shard" do
    let(:data) { "test file content".b }
    let(:chunk_hashes) { [hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data)] }
    let(:chunk_lengths) { [data.bytesize] }
    let(:chunks_info) { chunk_hashes.zip(chunk_lengths).map { |h, l| { hash: h, length: l } } }
    let(:xorb_hash) { hasher.compute_xorb_hash(chunks_info) }
    let(:file_hash) { hasher.compute_file_hash(xorb_hash) }
    let(:sha256) { Digest::SHA256.digest(data) }
    let(:range_hash) { hasher.compute_verification_hash(chunk_hashes) }
    let(:xorb_data) { serializer.serialize_xorb([data]) }

    let(:representation) do
      [{
        xorb_hash: xorb_hash,
        index_start: 0,
        index_end: 1,
        length: data.bytesize,
        range_hash: range_hash
      }]
    end

    it "builds shard with correct header" do
      shard = serializer.build_shard(
        file_hash: file_hash, representation: representation,
        chunk_hashes: chunk_hashes, chunk_lengths: chunk_lengths,
        xorb_hash: xorb_hash, xorb_serialized_size: xorb_data.bytesize,
        sha256: sha256
      )
      expect(shard.byteslice(0, 32)).to eq(described_class::SHARD_TAG)
      expect(shard.byteslice(32, 8).unpack1("Q<")).to eq(2)
      expect(shard.byteslice(40, 8).unpack1("Q<")).to eq(200)
    end

    it "produces binary output" do
      shard = serializer.build_shard(
        file_hash: file_hash, representation: representation,
        chunk_hashes: chunk_hashes, chunk_lengths: chunk_lengths,
        xorb_hash: xorb_hash, xorb_serialized_size: xorb_data.bytesize,
        sha256: sha256
      )
      expect(shard.encoding).to eq(Encoding::ASCII_8BIT)
      expect(shard.bytesize).to be > described_class::SHARD_HEADER_SIZE + described_class::SHARD_FOOTER_SIZE
    end
  end

  describe HuggingFaceStorage::XetStreamRepresentationBuilder do
    subject(:builder) { described_class.new(hasher) }

    let(:hasher) { HuggingFaceStorage::XetHasher.new }
    let(:serializer) { HuggingFaceStorage::XetSerializer.new(hasher) }

    it "can be created via stream_representation_builder factory" do
      builder = serializer.stream_representation_builder
      expect(builder).to be_a(described_class)
      expect(builder.finalize).to eq([])
    end

    it "builds representation incrementally as xorbs complete" do
      builder.start_xorb
      3.times { builder.add_chunk(Random.bytes(32), 4096) }
      builder.finalize_xorb("xorb_0_hash")

      builder.start_xorb
      2.times { builder.add_chunk(Random.bytes(32), 8192) }
      builder.finalize_xorb("xorb_1_hash")

      builder.start_xorb
      builder.add_chunk(Random.bytes(32), 1024)
      builder.finalize_xorb("xorb_2_hash")

      rep = builder.finalize
      expect(rep.size).to eq(3)
      expect(rep[0][:xorb_hash]).to eq("xorb_0_hash")
      expect(rep[0][:index_start]).to eq(0)
      expect(rep[0][:index_end]).to eq(3)

      expect(rep[1][:xorb_hash]).to eq("xorb_1_hash")
      expect(rep[1][:index_start]).to eq(0)
      expect(rep[1][:index_end]).to eq(2)

      expect(rep[2][:xorb_hash]).to eq("xorb_2_hash")
      expect(rep[2][:index_start]).to eq(0)
      expect(rep[2][:index_end]).to eq(1)
    end

    it "computes range hashes using verification hash" do
      chunk_hash = Random.bytes(32)
      allow(hasher).to receive(:compute_verification_hash).and_call_original
      expect(hasher).to receive(:compute_verification_hash).with([chunk_hash]).once

      builder.start_xorb
      builder.add_chunk(chunk_hash, 4096)
      builder.finalize_xorb("hash")
      builder.finalize
    end

    it "handles empty builder" do
      expect(builder.finalize).to eq([])
    end

    it "matches build_representation output for consecutive chunks" do
      chunk_data = 6.times.map { |_i| Random.bytes(64) }
      chunks = chunk_data.map { |d| { data: d, hash: hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, d), length: d.bytesize } }

      xorbs = serializer.pack_xorbs(chunks)
      rep_from_build = serializer.build_representation(0, chunks.length, chunks, xorbs)

      builder = described_class.new(hasher)
      xorbs.each do |xorb|
        builder.start_xorb
        xorb[:chunks].each { |c| builder.add_chunk(c[:hash], c[:length]) }
        builder.finalize_xorb(xorb[:hash])
      end
      rep_from_stream = builder.finalize

      expect(rep_from_stream.size).to eq(rep_from_build.size)
      rep_from_stream.zip(rep_from_build).each do |s, b|
        expect(s[:xorb_hash]).to eq(b[:xorb_hash])
        expect(s[:index_start]).to eq(b[:index_start])
        expect(s[:index_end]).to eq(b[:index_end])
        expect(s[:length]).to eq(b[:length])
        expect(s[:range_hash]).to eq(b[:range_hash])
      end
    end
  end
end
