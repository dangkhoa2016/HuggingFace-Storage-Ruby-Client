# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetHasher do
  let(:hasher) { described_class.new }

  # ── Constants ──

  describe "constants" do
    it "has correct chunk sizes" do
      expect(described_class::TARGET_CHUNK).to eq(65_536)
      expect(described_class::MIN_CHUNK).to eq(8_192)
      expect(described_class::MAX_CHUNK).to eq(131_072)
    end

    it "has correct xorb limits" do
      expect(described_class::XORB_MAX_SIZE).to eq(64 * 1024 * 1024)
      expect(described_class::XORB_MAX_CHUNKS).to eq(8 * 1024)
    end

    it "has 256-entry gearhash table" do
      expect(HuggingFaceStorage::GEARHASH_TABLE.size).to eq(256)
    end

    it "has 32-byte blake3 keys" do
      expect(described_class::DATA_KEY.bytesize).to eq(32)
      expect(described_class::NODE_KEY.bytesize).to eq(32)
      expect(described_class::VERIFICATION_KEY.bytesize).to eq(32)
      expect(described_class::ZERO_KEY.bytesize).to eq(32)
    end
  end

  # ── Blake3 keyed hashing ──

  describe "#blake3_keyed" do
    it "produces 32-byte hash" do
      result = hasher.blake3_keyed(described_class::DATA_KEY, "hello world")
      expect(result.bytesize).to eq(32)
    end

    it "produces deterministic output" do
      a = hasher.blake3_keyed(described_class::DATA_KEY, "test data")
      b = hasher.blake3_keyed(described_class::DATA_KEY, "test data")
      expect(a).to eq(b)
    end

    it "produces different hashes for different keys" do
      a = hasher.blake3_keyed(described_class::DATA_KEY, "same data")
      b = hasher.blake3_keyed(described_class::ZERO_KEY, "same data")
      expect(a).not_to eq(b)
    end

    it "produces different hashes for different data" do
      a = hasher.blake3_keyed(described_class::DATA_KEY, "data1")
      b = hasher.blake3_keyed(described_class::DATA_KEY, "data2")
      expect(a).not_to eq(b)
    end
  end

  describe "#batch_blake3_keyed", :slow do
    it "returns same results as sequential blake3_keyed" do
      key = described_class::DATA_KEY
      data1 = "hello"
      data2 = "world"
      data3 = "batch test"

      expected = [
        hasher.blake3_keyed(key, data1),
        hasher.blake3_keyed(key, data2),
        hasher.blake3_keyed(key, data3),
      ]

      actual = hasher.batch_blake3_keyed(key, [data1, data2, data3], num_threads: 2)
      expect(actual).to eq(expected)
    end

    it "handles empty array" do
      expect(hasher.batch_blake3_keyed(described_class::DATA_KEY, [])).to eq([])
    end

    it "handles single item" do
      key = described_class::DATA_KEY
      expected = hasher.blake3_keyed(key, "single")
      expect(hasher.batch_blake3_keyed(key, ["single"])).to eq([expected])
    end

    it "uses thread-local buffers for thread safety" do
      data = 20.times.map { |i| "chunk #{i}" }
      key = described_class::DATA_KEY
      results = hasher.batch_blake3_keyed(key, data, num_threads: 4)
      expected = data.map { |d| hasher.blake3_keyed(key, d) }
      expect(results).to eq(expected)
    end

    it "raises CancelledError when cancel_token is already cancelled" do
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      expect do
        hasher.batch_blake3_keyed(described_class::DATA_KEY, %w[a b c], cancel_token: token)
      end.to raise_error(HuggingFaceStorage::CancelledError, /cancelled/i)
    end

    it "cleans up pool via shutdown_pool" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "payload-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      expect { hasher.shutdown_pool }.not_to raise_error
    end

    it "reuses the pool across batch calls and resizes when needed" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "payload-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool).to be_a(HuggingFaceStorage::Blake3Pool)
      expect(pool.size).to eq(2)
      hasher.batch_blake3_keyed(key, data, num_threads: 4)
      pool2 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool2).to be_a(HuggingFaceStorage::Blake3Pool)
      expect(pool2.size).to eq(4)
    end

    it "propagates CancelledError when token is cancelled mid-batch" do
      token = HuggingFaceStorage::CancelToken.new
      key = described_class::DATA_KEY
      big = Array.new(2000) { |i| ("x" * 4096) + i.to_s }
      started = Queue.new

      worker = Thread.new do
        started.push(true)
        hasher.batch_blake3_keyed(key, big, num_threads: 2, cancel_token: token)
      end

      started.pop
      token.cancel!

      expect { worker.value }.to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "allows a fresh pool on the same thread after cancellation" do
      key = described_class::DATA_KEY
      token = HuggingFaceStorage::CancelToken.new
      big = Array.new(2000) { |i| ("x" * 4096) + i.to_s }
      started = Queue.new

      worker = Thread.new do
        started.push(true)
        hasher.batch_blake3_keyed(key, big, num_threads: 2, cancel_token: token)
      end

      started.pop
      token.cancel!

      expect { worker.value }.to raise_error(HuggingFaceStorage::CancelledError)
      data = 8.times.map { |i| "after-cancel-#{i}" }
      results = hasher.batch_blake3_keyed(key, data, num_threads: 2)
      expected = data.map { |d| hasher.blake3_keyed(key, d) }
      expect(results).to eq(expected)
    end
  end

  # ── CDC Chunking ──

  describe "#cdc_chunk" do
    it "returns single chunk for small data" do
      data = "small data".b
      chunks = hasher.cdc_chunk(data)
      expect(chunks.size).to eq(1)
      expect(chunks[0]).to eq([0, data.bytesize])
    end

    it "returns single chunk for data at MIN_CHUNK boundary" do
      data = ("x" * described_class::MIN_CHUNK).b
      chunks = hasher.cdc_chunk(data)
      expect(chunks.size).to eq(1)
      expect(chunks[0]).to eq([0, data.bytesize])
    end

    it "chunks large data into multiple pieces" do
      data = Random.new(42).bytes(200_000).b
      chunks = hasher.cdc_chunk(data)
      expect(chunks.size).to be > 1
      expect(chunks.first[0]).to eq(0)
      expect(chunks.last[1]).to eq(data.bytesize)
      chunks.each_cons(2) do |a, b|
        expect(a[1]).to eq(b[0])
      end
    end

    it "respects MIN_CHUNK minimum size" do
      data = Random.new(123).bytes(50_000).b
      chunks = hasher.cdc_chunk(data)
      chunks[0...-1].each do |start_pos, end_pos|
        expect(end_pos - start_pos).to be >= described_class::MIN_CHUNK
      end
    end

    it "respects MAX_CHUNK maximum size" do
      data = Random.new(456).bytes(200_000).b
      chunks = hasher.cdc_chunk(data)
      chunks.each do |start_pos, end_pos|
        expect(end_pos - start_pos).to be <= described_class::MAX_CHUNK
      end
    end

    it "handles empty data" do
      chunks = hasher.cdc_chunk("".b)
      expect(chunks.size).to eq(1)
      expect(chunks[0]).to eq([0, 0])
    end

    it "falls back to cdc_chunk_ruby when native CDC is not available" do
      allow(described_class).to receive(:native_available?).and_return(false)
      chunks = hasher.cdc_chunk("hello world".b)
      expect(chunks).to be_an(Array)
      expect(chunks.first).to be_an(Array)
      expect(chunks.first.size).to eq(2)
    end

    it "can be called directly via cdc_chunk_ruby for testing" do
      data = "small data".b
      small_chunks = hasher.cdc_chunk_ruby(data)
      expect(small_chunks.size).to eq(1)
      expect(small_chunks[0]).to eq([0, data.bytesize])

      large_data = Random.new(42).bytes(200_000).b
      large_chunks = hasher.cdc_chunk_ruby(large_data)
      expect(large_chunks.size).to be > 1
      expect(large_chunks.first[0]).to eq(0)
      expect(large_chunks.last[1]).to eq(large_data.bytesize)
      large_chunks.each_cons(2) do |a, b|
        expect(a[1]).to eq(b[0])
      end
    end
  end

  # ── Xorb Hash ──

  describe "#compute_xorb_hash" do
    it "returns zero hash for empty input" do
      result = hasher.compute_xorb_hash([])
      expect(result).to eq(("\x00" * 32).b)
    end

    it "returns chunk hash directly for single chunk" do
      data = "small".b
      chunk_hash = hasher.blake3_keyed(described_class::DATA_KEY, data)
      result = hasher.compute_xorb_hash([{ hash: chunk_hash, length: data.bytesize }])
      expect(result).to eq(chunk_hash)
    end

    it "returns merged hash for multiple chunks" do
      chunks = 5.times.map do |i|
        data = "chunk#{i}".b
        hash = hasher.blake3_keyed(described_class::DATA_KEY, data)
        { hash: hash, length: data.bytesize }
      end
      result = hasher.compute_xorb_hash(chunks)
      expect(result.bytesize).to eq(32)
    end

    it "is deterministic" do
      chunks = 3.times.map do |i|
        data = "data#{i}".b
        hash = hasher.blake3_keyed(described_class::DATA_KEY, data)
        { hash: hash, length: data.bytesize }
      end
      a = hasher.compute_xorb_hash(chunks)
      b = hasher.compute_xorb_hash(chunks)
      expect(a).to eq(b)
    end

    it "accepts both Array and Hash format" do
      data = "test".b
      hash = hasher.blake3_keyed(described_class::DATA_KEY, data)
      array_result = hasher.compute_xorb_hash([[hash, data.bytesize]])
      hash_result = hasher.compute_xorb_hash([{ hash: hash, length: data.bytesize }])
      expect(array_result).to eq(hash_result)
    end
  end

  # ── File Hash ──

  describe "#compute_file_hash" do
    it "computes blake3_keyed(ZERO_KEY, xorb_hash)" do
      xorb_hash = ("\xAB" * 32).b
      result = hasher.compute_file_hash(xorb_hash)
      expected = hasher.blake3_keyed(described_class::ZERO_KEY, xorb_hash)
      expect(result).to eq(expected)
    end
  end

  # ── Verification Hash ──

  describe "#compute_verification_hash" do
    it "computes blake3_keyed(VERIFICATION_KEY, joined chunk hashes)" do
      hashes = [("\x01" * 32).b, ("\x02" * 32).b]
      result = hasher.compute_verification_hash(hashes)
      expected = hasher.blake3_keyed(described_class::VERIFICATION_KEY, hashes.join.b)
      expect(result).to eq(expected)
    end
  end

  # ── find_blake3_so ──

  describe ".find_blake3_so" do
    around do |example|
      old = described_class.instance_variable_get(:@find_blake3_so)
      described_class.instance_variable_set(:@find_blake3_so, nil)
      begin
        example.run
      ensure
        described_class.instance_variable_set(:@find_blake3_so, old)
      end
    end

    it "falls back to Gem::Specification.find_by_name when Gem.find_files is empty" do
      allow(Gem).to receive(:find_files).with("digest/blake3/blake3.so").and_return([])
      spec = instance_double(Gem::Specification, gem_dir: "/tmp/fake_gem_dir")
      allow(Gem::Specification).to receive(:find_by_name).with("digest-blake3").and_return(spec)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/tmp/fake_gem_dir/lib/digest/blake3/blake3.so").and_return(true)

      path = described_class.find_blake3_so
      expect(path).to eq("/tmp/fake_gem_dir/lib/digest/blake3/blake3.so")
    end

    it "falls back to Dir.glob when Gem.find_files and find_by_name are empty" do
      allow(Gem).to receive(:find_files).with("digest/blake3/blake3.so").and_return([])
      allow(Gem::Specification).to receive(:find_by_name).with("digest-blake3").and_raise(Gem::MissingSpecError.new("digest-blake3",
">= 0"))

      pattern1 = File.join(Gem.user_dir, "gems", "digest-blake3-*", "lib", "digest", "blake3", "blake3.so")
      pattern2 = File.join(Gem.dir, "gems", "digest-blake3-*", "lib", "digest", "blake3", "blake3.so")
      allow(Dir).to receive(:glob).and_return([])
      allow(Dir).to receive(:glob).with(pattern1).and_return(["/fake/glob/path/blake3.so"])
      allow(Dir).to receive(:glob).with(pattern2).and_return([])
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/fake/glob/path/blake3.so").and_return(true)

      path = described_class.find_blake3_so
      expect(path).to eq("/fake/glob/path/blake3.so")
    end

    it "falls back to RbConfig::CONFIG sitearchdir when all gem lookups fail" do
      allow(Gem).to receive(:find_files).with("digest/blake3/blake3.so").and_return([])
      allow(Gem::Specification).to receive(:find_by_name).with("digest-blake3").and_raise(Gem::MissingSpecError.new("digest-blake3",
">= 0"))
      allow(Dir).to receive(:glob).and_return([])
      allow(RbConfig::CONFIG).to receive(:[]).and_call_original
      allow(RbConfig::CONFIG).to receive(:[]).with("sitearchdir").and_return("/fake/arch")
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/fake/arch/digest/blake3/blake3.so").and_return(true)

      path = described_class.find_blake3_so
      expect(path).to eq("/fake/arch/digest/blake3/blake3.so")
    end
  end

  describe ".native_available?" do
    it "returns false when C extension is not compiled" do
      described_class.instance_variable_set(:@native_available, nil)
      allow(described_class).to receive(:require).with("hugging_face_storage/gearhash").and_raise(LoadError)
      expect(described_class.native_available?).to be false
    end
  end

  describe "._load_native" do
    it "returns true when require succeeds" do
      allow(described_class).to receive(:require).with("hugging_face_storage/gearhash").and_return(true)
      expect(described_class._load_native).to be true
    end

    it "returns false when require raises LoadError" do
      allow(described_class).to receive(:require).with("hugging_face_storage/gearhash").and_raise(LoadError)
      expect(described_class._load_native).to be false
    end
  end

  describe "Blake3Buffers" do
    it "allocates native memory and registers a finalizer" do
      bufs = HuggingFaceStorage::Blake3Buffers.new
      expect(bufs.hasher_buf).to be_a(Fiddle::Pointer)
      expect(bufs.hasher_buf.size).to eq(described_class::HASHER_SIZE)
      expect(bufs.out_buf).to be_a(Fiddle::Pointer)
      expect(bufs.out_buf.size).to eq(described_class::OUT_LEN)
    end

    it "frees native memory" do
      bufs = HuggingFaceStorage::Blake3Buffers.new
      expect { bufs.free }.not_to raise_error
    end
  end

  describe "#cdc_chunk with native path" do
    it "delegates to Gearhash.cdc_chunk when native is available" do
      allow(described_class).to receive(:native_available?).and_return(true)
      gearhash_mod = Module.new do
        def self.cdc_chunk(data, mask, min_c, max_c, table)
          [[0, data.bytesize]]
        end
      end
      stub_const("HuggingFaceStorage::Gearhash", gearhash_mod)

      result = hasher.cdc_chunk("test_data!")
      expect(result).to eq([[0, 10]])
    end
  end
end
