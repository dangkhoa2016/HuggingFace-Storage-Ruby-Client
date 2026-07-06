# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Property-based: CDC chunking", :slow do
  let(:hasher) { HuggingFaceStorage::XetHasher.new }

  describe "chunk coverage" do
    it "chunks always cover the entire data without gaps" do
      100.times do
        size = rand(1..100_000)
        data = Random.bytes(size)
        chunks = hasher.cdc_chunk(data)

        total_size = chunks.sum { |s, e| e - s }
        expect(total_size).to eq(data.bytesize), "Chunks must cover all #{size} bytes"
      end
    end

    it "chunks are contiguous (no overlaps, no gaps)" do
      100.times do
        size = rand(1000..100_000)
        data = Random.bytes(size)
        chunks = hasher.cdc_chunk(data)

        chunks.each_cons(2) do |(s1, e1), (s2, e2)|
          expect(s2).to eq(e1), "Chunk [#{s1},#{e1}) must be followed by [#{e1},...)"
        end
      end
    end

    it "first chunk starts at 0" do
      50.times do
        data = Random.bytes(rand(100..50_000))
        chunks = hasher.cdc_chunk(data)
        expect(chunks.first[0]).to eq(0)
      end
    end

    it "last chunk ends at data.bytesize" do
      50.times do
        size = rand(100..50_000)
        data = Random.bytes(size)
        chunks = hasher.cdc_chunk(data)
        expect(chunks.last[1]).to eq(size)
      end
    end
  end

  describe "chunk size bounds" do
    it "respects MIN_CHUNK for non-final chunks" do
      50.times do
        data = Random.bytes(rand(10_000..100_000))
        chunks = hasher.cdc_chunk(data)

        chunks[0..-2].each_with_index do |(s, e), i|
          size = e - s
          expect(size).to be >= HuggingFaceStorage::XetHasher::MIN_CHUNK,
            "Non-final chunk #{i} size #{size} < MIN_CHUNK"
        end
      end
    end

    it "respects MAX_CHUNK for all chunks" do
      50.times do
        data = Random.bytes(rand(10_000..100_000))
        chunks = hasher.cdc_chunk(data)

        chunks.each_with_index do |(s, e), i|
          size = e - s
          expect(size).to be <= HuggingFaceStorage::XetHasher::MAX_CHUNK,
            "Chunk #{i} size #{size} > MAX_CHUNK"
        end
      end
    end
  end

  describe "edge cases" do
    it "returns single chunk for empty data" do
      chunks = hasher.cdc_chunk("".b)
      expect(chunks).to eq([[0, 0]])
    end

    it "returns single chunk for data smaller than MIN_CHUNK" do
      data = Random.bytes(HuggingFaceStorage::XetHasher::MIN_CHUNK - 1)
      chunks = hasher.cdc_chunk(data)
      expect(chunks.size).to eq(1)
      expect(chunks[0]).to eq([0, data.bytesize])
    end

    it "returns single chunk for data exactly at MIN_CHUNK" do
      data = Random.bytes(HuggingFaceStorage::XetHasher::MIN_CHUNK)
      chunks = hasher.cdc_chunk(data)
      expect(chunks.size).to eq(1)
    end

    it "handles data with all zero bytes" do
      data = "\x00".b * 50_000
      chunks = hasher.cdc_chunk(data)
      total = chunks.sum { |s, e| e - s }
      expect(total).to eq(50_000)
    end

    it "handles data with all 0xFF bytes" do
      data = "\xFF".b * 50_000
      chunks = hasher.cdc_chunk(data)
      total = chunks.sum { |s, e| e - s }
      expect(total).to eq(50_000)
    end

    it "is deterministic" do
      data = Random.bytes(50_000)
      chunks1 = hasher.cdc_chunk(data)
      chunks2 = hasher.cdc_chunk(data)
      expect(chunks1).to eq(chunks2)
    end
  end

  describe "blake3 hashing properties" do
    it "produces 32-byte hashes" do
      20.times do
        data = Random.bytes(rand(1..10_000))
        hash = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data)
        expect(hash.bytesize).to eq(32)
      end
    end

    it "produces different hashes for different data" do
      h1 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, "data1".b)
      h2 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, "data2".b)
      expect(h1).not_to eq(h2)
    end

    it "produces different hashes for different keys" do
      data = "same data".b
      h1 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, data)
      h2 = hasher.blake3_keyed(HuggingFaceStorage::XetHasher::NODE_KEY, data)
      expect(h1).not_to eq(h2)
    end
  end

  describe "xorb hash tree properties" do
    it "returns zero hash for empty input" do
      result = hasher.compute_xorb_hash([])
      expect(result).to eq(("\x00" * 32).b)
    end

    it "is deterministic for same input" do
      data = Random.bytes(50_000)
      chunks = hasher.cdc_chunk(data)
      chunk_data = chunks.map { |s, e| data.byteslice(s, e - s) }
      hashes = chunk_data.map { |c| hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, c) }
      infos = hashes.zip(chunk_data.map(&:bytesize))

      h1 = hasher.compute_xorb_hash(infos)
      h2 = hasher.compute_xorb_hash(infos)
      expect(h1).to eq(h2)
    end

    it "produces different hashes for different chunk sets" do
      d1 = Random.bytes(50_000)
      d2 = Random.bytes(50_000)

      c1 = hasher.cdc_chunk(d1).map { |s, e| d1.byteslice(s, e - s) }
      c2 = hasher.cdc_chunk(d2).map { |s, e| d2.byteslice(s, e - s) }

      h1 = hasher.compute_xorb_hash(c1.map { |c|
        [hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, c), c.bytesize]
      })
      h2 = hasher.compute_xorb_hash(c2.map { |c|
        [hasher.blake3_keyed(HuggingFaceStorage::XetHasher::DATA_KEY, c), c.bytesize]
      })
      expect(h1).not_to eq(h2)
    end
  end
end
