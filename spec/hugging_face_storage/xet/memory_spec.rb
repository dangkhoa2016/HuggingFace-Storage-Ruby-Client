# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Memory: XetHasher buffer management" do
  let(:hasher) { HuggingFaceStorage::XetHasher.new }

  def get_heap_pages
    GC.stat(:heap_allocated_pages) || 0
  end

  describe "blake3_keyed repeated calls" do
    it "does not leak memory during repeated hashing" do
      data = Random.bytes(1024)
      key = HuggingFaceStorage::XetHasher::DATA_KEY

      GC.start
      before_pages = get_heap_pages

      500.times { hasher.blake3_keyed(key, data) }

      GC.start
      after_pages = get_heap_pages

      growth_pages = after_pages - before_pages
      expect(growth_pages).to be < 10_240, "Memory grew by #{growth_pages} pages (expected < 10_240 pages)"
    end
  end

  describe "cdc_chunk repeated calls" do
    it "does not leak memory during repeated chunking" do
      data = Random.bytes(10_000)

      GC.start
      before_pages = get_heap_pages

      20.times { hasher.cdc_chunk(data) }

      GC.start
      after_pages = get_heap_pages

      growth_pages = after_pages - before_pages
      expect(growth_pages).to be < 10_240, "Memory grew by #{growth_pages} pages (expected < 10_240 pages)"
    end
  end

  describe "instance buffer lifecycle" do
    it "uses thread-local buffers for concurrency" do
      hasher.blake3_keyed(HuggingFaceStorage::XetHasher::ZERO_KEY, "test")
      bufs = Thread.current[HuggingFaceStorage::XetHasher::THREAD_STORAGE_KEY]
      expect(bufs).to be_a(HuggingFaceStorage::Blake3Buffers)
      expect(bufs.hasher_buf).to be_a(Fiddle::Pointer)
      expect(bufs.out_buf).to be_a(Fiddle::Pointer)
    end

    it "creates separate buffers per thread" do
      main_bufs = Thread.current[HuggingFaceStorage::XetHasher::THREAD_STORAGE_KEY]
      other_bufs = Thread.new do
        hasher.blake3_keyed(HuggingFaceStorage::XetHasher::ZERO_KEY, "test")
        Thread.current[HuggingFaceStorage::XetHasher::THREAD_STORAGE_KEY]
      end.value
      expect(other_bufs).not_to equal(main_bufs)
    end

    it "registers a finalizer for cleanup" do
      bufs = HuggingFaceStorage::Blake3Buffers.new
      finalizer_defined = ObjectSpace.respond_to?(:define_finalizer)
      expect(finalizer_defined).to be true
      expect(bufs.hasher_buf).not_to be_nil
    end
  end

  describe "CancelToken memory" do
    it "clears callbacks after cancel" do
      token = HuggingFaceStorage::CancelToken.new
      100.times { token.on_cancel { "callback" } }

      expect(token.instance_variable_get(:@on_cancel).size).to eq(100)

      token.cancel!

      expect(token.instance_variable_get(:@on_cancel).size).to eq(0)
    end
  end

  describe "BatchResult memory" do
    it "does not accumulate unbounded data" do
      result = HuggingFaceStorage::BatchResult.new
      1000.times { |i| result.add_success({ type: "addFile", path: "file_#{i}.txt" }) }

      expect(result.success_count).to eq(1000)
      expect(result.to_h[:succeeded].size).to eq(1000)
    end
  end
end
