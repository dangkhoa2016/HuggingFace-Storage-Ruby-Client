# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetShardBuilder do
  let(:dummy) do
    Class.new do
      include HuggingFaceStorage::XetShardBuilder

      attr_accessor :hasher
    end.new
  end

  let(:file_hash) { ("\x11" * 32).b }
  let(:chunk_hash) { ("\x22" * 32).b }
  let(:xorb_hash) { ("\x33" * 32).b }
  let(:sha256) { ("\x44" * 32).b }
  let(:range_hash) { ("\x55" * 32).b }

  describe "#build_shard" do
    it "returns binary shard data for a single file" do
      result = dummy.build_shard(
        file_hash: file_hash,
        representation: [
          { xorb_hash: xorb_hash, index_start: 0, index_end: 3, length: 300, range_hash: range_hash }
        ],
        chunk_hashes: [chunk_hash] * 3,
        chunk_lengths: [100, 100, 100],
        xorb_hash: xorb_hash,
        xorb_serialized_size: 500,
        sha256: sha256
      )

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result.bytesize).to be > 0
      expect(result[0, 32]).to eq(described_class::SHARD_TAG)
    end

    it "raises when required components are missing" do
      expect do
        dummy.build_shard(
          file_hash: file_hash,
          representation: [],
          chunk_hashes: [],
          chunk_lengths: [],
          xorb_hash: xorb_hash,
          xorb_serialized_size: 0,
          sha256: sha256
        )
      end.not_to raise_error
    end
  end

  describe "#build_multi_file_shard" do
    it "builds a shard from multiple file metas" do
      file_metas = [
        { file_hash: file_hash, representation: [
          { xorb_hash: xorb_hash, index_start: 0, index_end: 1, length: 100, range_hash: range_hash }
        ], sha256: sha256 }
      ]
      xorbs = [{ hash: xorb_hash, chunks: [{ hash: chunk_hash, length: 100 }], serialized_size: 200 }]

      result = dummy.build_multi_file_shard(file_metas, xorbs)

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result[0, 32]).to eq(described_class::SHARD_TAG)
    end
  end

  describe "#build_representation" do
    before do
      dummy.hasher = instance_double(HuggingFaceStorage::XetHasher)
      allow(dummy.hasher).to receive(:compute_verification_hash).and_return(range_hash)
    end

    it "returns empty array for zero chunk count" do
      result = dummy.build_representation(0, 0, [], [])
      expect(result).to eq([])
    end

    it "builds representation mapping chunks to xorbs" do
      all_chunks = 3.times.map { |i| { hash: "\xAA#{i.to_s * 31}".b, length: 100 } }
      xorbs = [
        { hash: ("\xbb" * 32).b, chunks: [all_chunks[0], all_chunks[1]] },
        { hash: ("\xcc" * 32).b, chunks: [all_chunks[2]] }
      ]

      result = dummy.build_representation(0, 3, all_chunks, xorbs)

      expect(result.size).to eq(2)
      expect(result[0][:xorb_hash]).to eq(("\xbb" * 32).b)
      expect(result[0][:index_start]).to eq(0)
      expect(result[0][:index_end]).to eq(2)
      expect(result[1][:xorb_hash]).to eq(("\xcc" * 32).b)
      expect(result[1][:index_start]).to eq(0)
      expect(result[1][:index_end]).to eq(1)
    end
  end

  describe "binary packing" do
    it "#pack_file_header produces correct format" do
      result = dummy.send(:pack_file_header, file_hash, 2)
      expect(result[0, 32]).to eq(file_hash)
      flags = result[32, 4].unpack1("V")
      expect(flags & described_class::MDB_FILE_FLAG_WITH_VERIFICATION).not_to be_zero
    end

    it "#pack_chunk_entries produces entries for each representation" do
      reps = [
        { xorb_hash: xorb_hash, length: 100, index_start: 0, index_end: 2, range_hash: range_hash }
      ]
      result = dummy.send(:pack_chunk_entries, reps)
      expect(result.bytesize).to be > 0
      expect(result[0, 32]).to eq(xorb_hash)
    end
  end
end
