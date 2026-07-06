# frozen_string_literal: true

require "spec_helper"

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
  end
end
