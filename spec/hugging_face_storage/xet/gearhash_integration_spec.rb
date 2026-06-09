# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Gearhash C extension integration", :slow do
  # Trigger autoload of CdcChunker (and thus GEARHASH_TABLE) before specs
  before do
    HuggingFaceStorage::CdcChunker
  end

  let(:table) { HuggingFaceStorage::GEARHASH_TABLE }
  let(:chunker) { HuggingFaceStorage::CdcChunker.new(gearhash_table: table) }
  let(:mask) { HuggingFaceStorage::CdcChunker::MASK }
  let(:min_chunk) { HuggingFaceStorage::CdcChunker::MIN_CHUNK }
  let(:max_chunk) { HuggingFaceStorage::CdcChunker::MAX_CHUNK }

  def native_gearhash_available?
    @native_gearhash_available ||= begin
      require "hugging_face_storage/gearhash"
      true
    rescue LoadError
      false
    end
  end

  context "when C extension is available" do
    before do
      skip "Gearhash C extension not compiled" unless native_gearhash_available?
    end

    it "produces same results as Ruby implementation for empty data" do
      data = "".b
      native = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      ruby = chunker.cdc_chunk_ruby(data)
      expect(native).to eq(ruby)
    end

    it "produces same results as Ruby implementation for small data" do
      data = "a" * 100
      native = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      ruby = chunker.cdc_chunk_ruby(data)
      expect(native).to eq(ruby)
    end

    it "produces same results for data at min_chunk boundary" do
      data = "b" * min_chunk
      native = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      ruby = chunker.cdc_chunk_ruby(data)
      expect(native).to eq(ruby)
    end

    it "produces same results for data at max_chunk boundary" do
      data = "c" * (max_chunk + 1)
      native = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      ruby = chunker.cdc_chunk_ruby(data)
      expect(native).to eq(ruby)
    end

    it "produces same results for varied binary data" do
      data = Array.new(500) { rand(0..255) }.pack("C*")
      native = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      ruby = chunker.cdc_chunk_ruby(data)
      expect(native).to eq(ruby)
    end

    it "is deterministic" do
      data = "deterministic_test_data_" * 50
      a = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      b = HuggingFaceStorage::Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
      expect(a).to eq(b)
    end
  end
end
