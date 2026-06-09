# frozen_string_literal: true

require "spec_helper"
begin
  require "hugging_face_storage/gearhash"
rescue LoadError
  # native extension not compiled; tests will be skipped
end

RSpec.describe HuggingFaceStorage::XorbHashTree do
  subject(:tree) { described_class.new }

  describe "#build" do
    let(:empty_hash) { ([0] * 32).pack("C*") }

    it "returns empty xorb hash for zero chunks" do
      result = tree.build([])
      expect(result).to eq(empty_hash)
      expect(result.bytesize).to eq(32)
    end

    it "returns the single chunk hash unchanged" do
      chunk = (1..32).map(&:chr).join
      result = tree.build([chunk])
      expect(result).to eq(chunk)
    end

    it "produces correct xor for two chunks" do
      a = (1..32).map(&:chr).join
      b = (33..64).map(&:chr).join
      expected = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")

      result = tree.build([a, b])
      expect(result).to eq(expected)
    end

    it "produces correct xor for four chunks" do
      chunks = 4.times.map { |i| ((i * 32 + 1)..((i + 1) * 32)).map(&:chr).join }
      expected = chunks.map(&:bytes).reduce { |a, b| a.zip(b).map { |x, y| x ^ y } }.pack("C*")

      result = tree.build(chunks)
      expect(result).to eq(expected)
    end

    it "handles odd number of chunks by promoting the last one" do
      a = ([0xAB] * 32).pack("C*")
      b = ([0xCD] * 32).pack("C*")
      c = ([0xEF] * 32).pack("C*")
      ab = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")

      result = tree.build([a, b, c])
      expected = ab.bytes.zip(c.bytes).map { |x, y| x ^ y }.pack("C*")
      expect(result).to eq(expected)
    end

    it "returns a 32-byte binary string for any input" do
      result = tree.build(["\x01" * 32, "\x02" * 32])
      expect(result.bytesize).to eq(32)
      expect(result.encoding).to eq(Encoding::BINARY)
    end

    it "is deterministic for the same input" do
      input = 4.times.map { |i| ((i * 5 + 1)..((i + 1) * 5)).map(&:chr).join.ljust(32, "\x00") }
      expect(tree.build(input)).to eq(tree.build(input))
    end

    context "with validate: true" do
      it "raises ArgumentError for invalid hash sizes" do
        expect { tree.build(["\x01" * 16], validate: true) }.to raise_error(ArgumentError, /32 bytes/)
      end

      it "accepts valid 32-byte hashes" do
        chunk = "\x01" * 32
        expect { tree.build([chunk], validate: true) }.not_to raise_error
      end
    end

    context "with validate: false" do
      it "skips validation and returns result for single valid chunk" do
        chunk = "\x01" * 32
        result = tree.build([chunk], validate: false)
        expect(result).to eq(chunk)
      end

      it "skips validation for multiple valid chunks" do
        chunks = ["\x01" * 32, "\x02" * 32, "\x03" * 32]
        result = tree.build(chunks, validate: false)
        expect(result.bytesize).to eq(32)
      end

      it "still processes XOR reduction without validation overhead" do
        a = Random.new(100).bytes(32)
        b = Random.new(200).bytes(32)
        expected = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")
        result = tree.build([a, b], validate: false)
        expect(result).to eq(expected)
      end
    end
  end

  describe "bulk XOR" do
    let(:xor) { ->(a, b) { a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*") } }

    it "produces same result as byte-by-byte XOR" do
      a = Random.new(1).bytes(32)
      b = Random.new(2).bytes(32)
      expected = xor.call(a, b)

      result = tree.build([a, b])
      expect(result).to eq(expected)
    end

    it "handles all-zero inputs" do
      a = ("\x00" * 32).b
      b = ("\x00" * 32).b
      expected = xor.call(a, b)

      result = tree.build([a, b])
      expect(result).to eq(expected)
    end

    it "handles all-ones XOR all-zeros" do
      a = ("\xFF" * 32).b
      b = ("\x00" * 32).b
      expected = xor.call(a, b)

      result = tree.build([a, b])
      expect(result).to eq(expected)
    end

    it "is associative for three chunks" do
      a = Random.new(10).bytes(32)
      b = Random.new(20).bytes(32)
      c = Random.new(30).bytes(32)

      ab_c = tree.build([a, b, c])
      abc_manual = xor.call(xor.call(a, b), c)
      expect(ab_c).to eq(abc_manual)
    end

    it "handles many chunks with random data" do
      chunks = 16.times.map { |i| Random.new(i).bytes(32) }
      result = tree.build(chunks)

      expected = chunks.reduce { |acc, chunk| xor.call(acc, chunk) }
      expect(result).to eq(expected)
    end
  end
end
