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

  describe "#batch_blake3_keyed" do
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

    it "uses sequential path when data_array.size < BATCH_PARALLEL_THRESHOLD" do
      key = described_class::DATA_KEY
      data = %w[alpha beta]
      expected = data.map { |d| hasher.blake3_keyed(key, d) }
      actual = hasher.batch_blake3_keyed(key, data, num_threads: 2)
      expect(actual).to eq(expected)
    end

    it "calls shutdown_pool on CancelledError during parallel hashing" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      pool = instance_double(HuggingFaceStorage::Blake3Pool)
      allow(pool).to receive(:map).and_raise(HuggingFaceStorage::CancelledError)
      allow(hasher).to receive(:thread_local_pool).and_return(pool)

      expect(hasher).to receive(:shutdown_pool).once
      expect { hasher.batch_blake3_keyed(key, data, num_threads: 2) }
        .to raise_error(HuggingFaceStorage::CancelledError)
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

    it "creates a new pool when size changes" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool_before = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      hasher.batch_blake3_keyed(key, data, num_threads: 4)
      pool_after = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool_after).not_to equal(pool_before)
      expect(pool_after.size).to eq(4)
    end
  end

  describe "#batch_blake3_keyed_from_ranges" do
    let(:key) { described_class::DATA_KEY }

    it "returns same results as sequential blake3_keyed with byteslice" do
      data = ("hello world this is test data for hashing" * 10).b
      ranges = [[0, 10], [10, 25], [25, 40]]

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)

      expect(actual).to eq(expected)
    end

    it "handles empty ranges" do
      data = "some data".b
      expect(hasher.batch_blake3_keyed_from_ranges(key, data, [], num_threads: 2)).to eq([])
    end

    it "handles single range" do
      data = "single chunk data".b
      ranges = [[0, data.bytesize]]
      expected = [hasher.blake3_keyed(key, data)]
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      expect(actual).to eq(expected)
    end

    it "handles ranges that don't start at offset 0" do
      data = ("a" * 100).b
      ranges = [[10, 30], [50, 80]]
      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      expect(actual).to eq(expected)
    end

    it "produces correct hashes for varying chunk sizes" do
      data = Random.new(42).bytes(100_000).b
      ranges = [[0, 8192], [8192, 24576], [24576, 65536], [65536, 100000]]

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 4)

      expect(actual).to eq(expected)
      expect(actual.size).to eq(4)
      actual.each { |h| expect(h.bytesize).to eq(32) }
    end

    it "uses sequential path when ranges.size < BATCH_PARALLEL_THRESHOLD" do
      data = "test data for sequential fallback".b
      ranges = [[0, 10], [10, 20]]
      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      expect(actual).to eq(expected)
    end

    it "uses sequential path when num_threads is 1" do
      data = ("x" * 10_000).b
      ranges = 5.times.map { |i| [i * 2000, (i + 1) * 2000] }
      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 1)
      expect(actual).to eq(expected)
    end

    it "handles large number of ranges across multiple threads" do
      data = Random.new(99).bytes(200_000).b
      chunk_size = 1000
      ranges = 50.times.map { |i| [i * chunk_size, (i + 1) * chunk_size] }

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      actual = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 4)

      expect(actual).to eq(expected)
      expect(actual.size).to eq(50)
    end

    it "preserves order of results" do
      data = ("abcdefghij" * 100).b
      ranges = 10.times.map { |i| [i * 10, (i + 1) * 10] }

      results = hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 4)

      ranges.each_with_index do |(s, e), i|
        expected = hasher.blake3_keyed(key, data.byteslice(s, e - s))
        expect(results[i]).to eq(expected)
      end
    end

    it "calls shutdown_pool on CancelledError during parallel hashing" do
      data = ("x" * 500_000).b
      ranges = 10.times.map { |i| [i * 50_000, (i + 1) * 50_000] }
      pool = instance_double(HuggingFaceStorage::Blake3Pool)
      allow(pool).to receive(:map_from_buffer).and_raise(HuggingFaceStorage::CancelledError)
      allow(hasher).to receive(:thread_local_pool).and_return(pool)

      expect(hasher).to receive(:shutdown_pool).once
      expect { hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "raises CancelledError when cancel_token is already cancelled" do
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      data = ("x" * 1000).b
      ranges = [[0, 500], [500, 1000]]
      expect do
        hasher.batch_blake3_keyed_from_ranges(key, data, ranges, cancel_token: token)
      end.to raise_error(HuggingFaceStorage::CancelledError, /cancelled/i)
    end

    it "propagates CancelledError when token is cancelled mid-batch" do
      token = HuggingFaceStorage::CancelToken.new
      data = Random.new(7).bytes(500_000).b
      ranges = 100.times.map { |i| [i * 5000, (i + 1) * 5000] }
      started = Queue.new

      worker = Thread.new do
        started.push(true)
        hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2, cancel_token: token)
      end

      started.pop
      token.cancel!

      expect { worker.value }.to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "allows a fresh pool on the same thread after cancellation" do
      token = HuggingFaceStorage::CancelToken.new
      data = Random.new(8).bytes(500_000).b
      ranges = 100.times.map { |i| [i * 5000, (i + 1) * 5000] }
      started = Queue.new

      worker = Thread.new do
        started.push(true)
        hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2, cancel_token: token)
      end

      started.pop
      token.cancel!

      expect { worker.value }.to raise_error(HuggingFaceStorage::CancelledError)

      small_data = "after cancel".b * 100
      small_ranges = [[0, 50], [50, 100]]
      results = hasher.batch_blake3_keyed_from_ranges(key, small_data, small_ranges, num_threads: 2)
      expected = small_ranges.map { |s, e| hasher.blake3_keyed(key, small_data.byteslice(s, e - s)) }
      expect(results).to eq(expected)
    end

    it "reuses thread-local pool across calls" do
      data = ("x" * 10_000).b
      ranges = 8.times.map { |i| [i * 1000, (i + 1) * 1000] }

      hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      pool1 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]

      hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      pool2 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]

      expect(pool2).to equal(pool1)
    end

    it "creates new pool when thread count changes" do
      data = ("x" * 500_000).b
      ranges = 8.times.map { |i| [i * 62_500, (i + 1) * 62_500] }

      hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 2)
      pool1 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]

      hasher.batch_blake3_keyed_from_ranges(key, data, ranges, num_threads: 4)
      pool2 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]

      expect(pool2).not_to equal(pool1)
      expect(pool2.size).to eq(4)
    end
  end

  describe "Gearhash.blake3_batch_keyed_from_ranges (C extension)" do
    let(:key) { described_class::DATA_KEY }

    it "produces concatenated hashes matching sequential blake3_keyed" do
      data = ("hello world this is test data for hashing" * 10).b
      ranges = [[0, 10], [10, 25], [25, 40]]

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }.join
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)

      expect(actual).to eq(expected)
      expect(actual.bytesize).to eq(ranges.size * 32)
    end

    it "handles empty ranges" do
      data = "some data".b
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, [], key)
      expect(actual).to eq("")
    end

    it "handles single range" do
      data = "single chunk data".b
      ranges = [[0, data.bytesize]]
      expected = hasher.blake3_keyed(key, data)
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)
      expect(actual).to eq(expected)
      expect(actual.bytesize).to eq(32)
    end

    it "handles ranges that don't start at offset 0" do
      data = ("a" * 100).b
      ranges = [[10, 30], [50, 80]]
      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }.join
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)

      expect(actual).to eq(expected)
    end

    it "produces correct hashes for varying chunk sizes" do
      data = Random.new(42).bytes(100_000).b
      ranges = [[0, 8192], [8192, 24576], [24576, 65536], [65536, 100000]]

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }.join
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)

      expect(actual).to eq(expected)
      expect(actual.bytesize).to eq(4 * 32)
    end

    it "preserves order of results" do
      data = ("abcdefghij" * 100).b
      ranges = 10.times.map { |i| [i * 10, (i + 1) * 10] }

      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)

      ranges.each_with_index do |(s, e), i|
        expected_hash = hasher.blake3_keyed(key, data.byteslice(s, e - s))
        expect(actual.byteslice(i * 32, 32)).to eq(expected_hash)
      end
    end

    it "handles large number of chunks efficiently" do
      data = Random.new(99).bytes(200_000).b
      chunk_size = 1000
      ranges = 50.times.map { |i| [i * chunk_size, (i + 1) * chunk_size] }

      expected = ranges.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }.join
      actual = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)

      expect(actual).to eq(expected)
      expect(actual.bytesize).to eq(50 * 32)
    end
  end

  describe "Gearhash.cdc_and_hash (C extension)" do
    let(:key) { described_class::DATA_KEY }
    let(:table) { HuggingFaceStorage::GEARHASH_TABLE }
    let(:mask) { HuggingFaceStorage::XetHasher::MASK }
    let(:min_chunk) { HuggingFaceStorage::XetHasher::MIN_CHUNK }
    let(:max_chunk) { HuggingFaceStorage::XetHasher::MAX_CHUNK }

    it "returns ranges and concatenated hashes matching separate CDC + Blake3" do
      data = ("hello world this is test data for hashing" * 100).b

      expected_ranges = hasher.cdc_chunk(data)
      expected_hashes = expected_ranges.map { |s, e|
        hasher.blake3_keyed(key, data.byteslice(s, e - s))
      }.join

      ranges, hashes = HuggingFaceStorage::Gearhash.cdc_and_hash(data, table, key, mask, min_chunk, max_chunk)

      expect(ranges).to eq(expected_ranges)
      expect(hashes).to eq(expected_hashes)
      expect(hashes.bytesize).to eq(ranges.size * 32)
    end

    it "handles small data (single chunk)" do
      data = "small".b

      ranges, hashes = HuggingFaceStorage::Gearhash.cdc_and_hash(data, table, key, mask, min_chunk, max_chunk)

      expect(ranges.size).to eq(1)
      expect(ranges[0]).to eq([0, data.bytesize])
      expect(hashes.bytesize).to eq(32)
    end

    it "handles 1MB data" do
      data = Random.new(42).bytes(1_000_000).b

      expected_ranges = hasher.cdc_chunk(data)
      expected_hashes = expected_ranges.map { |s, e|
        hasher.blake3_keyed(key, data.byteslice(s, e - s))
      }.join

      ranges, hashes = HuggingFaceStorage::Gearhash.cdc_and_hash(data, table, key, mask, min_chunk, max_chunk)

      expect(ranges).to eq(expected_ranges)
      expect(hashes).to eq(expected_hashes)
    end

    it "handles 10MB data" do
      data = Random.new(99).bytes(10_000_000).b

      expected_ranges = hasher.cdc_chunk(data)
      expected_hashes = expected_ranges.map { |s, e|
        hasher.blake3_keyed(key, data.byteslice(s, e - s))
      }.join

      ranges, hashes = HuggingFaceStorage::Gearhash.cdc_and_hash(data, table, key, mask, min_chunk, max_chunk)

      expect(ranges).to eq(expected_ranges)
      expect(hashes).to eq(expected_hashes)
      expect(hashes.bytesize).to eq(ranges.size * 32)
    end
  end

  describe "#shutdown_pool" do
    it "shuts down all thread-local pools" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool).to be_a(HuggingFaceStorage::Blake3Pool)
      hasher.shutdown_pool
      expect(Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]).to be_nil
    end

    it "iterates threads and cleans up pools on other threads" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      other_thread_pool = nil
      t = Thread.new do
        hasher.batch_blake3_keyed(key, data, num_threads: 2)
        other_thread_pool = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
        sleep 5
      end
      sleep 0.1
      hasher.shutdown_pool
      t.join(10)
      expect(other_thread_pool).to be_a(HuggingFaceStorage::Blake3Pool)
    end
  end

  describe "#thread_local_pool" do
    it "returns existing pool when size matches" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool1 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool2 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool2).to equal(pool1)
    end

    it "shuts down old pool and creates new one when size differs" do
      key = described_class::DATA_KEY
      data = Array.new(8) { |i| "chunk-#{i}" }
      hasher.batch_blake3_keyed(key, data, num_threads: 2)
      pool1 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      allow(pool1).to receive(:shutdown).and_call_original
      hasher.batch_blake3_keyed(key, data, num_threads: 4)
      pool2 = Thread.current[HuggingFaceStorage::XetHasher::THREAD_POOL_KEY]
      expect(pool1).to have_received(:shutdown)
      expect(pool2.size).to eq(4)
    end
  end

  describe "Gearhash.full_pipeline (C extension)" do
    let(:key) { described_class::DATA_KEY }
    let(:table) { HuggingFaceStorage::GEARHASH_TABLE }
    let(:mask) { HuggingFaceStorage::XetHasher::MASK }
    let(:min_chunk) { HuggingFaceStorage::XetHasher::MIN_CHUNK }
    let(:max_chunk) { HuggingFaceStorage::XetHasher::MAX_CHUNK }

    it "returns xorb_data matching separate serialize_xorb_from_ranges" do
      data = ("hello world this is test data for pipeline" * 100).b

      ranges = hasher.cdc_chunk(data)
      hashes = HuggingFaceStorage::Gearhash.blake3_batch_keyed_from_ranges(data, ranges, key)
      chunk_lengths = ranges.map { |s, e| e - s }
      expected_xorb = HuggingFaceStorage::Gearhash.serialize_xorb_from_ranges(data, ranges)

      result = HuggingFaceStorage::Gearhash.full_pipeline(data, table, key, mask, min_chunk, max_chunk)
      hashes_concat, result_ranges, xorb_data = result

      expect(xorb_data).to eq(expected_xorb)
      expect(result_ranges.size).to eq(ranges.size)
      expect(hashes_concat.bytesize).to eq(ranges.size * 32)
    end

    it "handles small data (single chunk)" do
      data = "small".b

      result = HuggingFaceStorage::Gearhash.full_pipeline(data, table, key, mask, min_chunk, max_chunk)
      hashes_concat, result_ranges, xorb_data = result

      expect(result_ranges.size).to eq(1)
      expect(xorb_data).to be_a(String)
      expect(xorb_data.bytesize).to be > 0
      expect(hashes_concat.bytesize).to eq(32)
    end

    it "handles 1MB data" do
      data = Random.new(42).bytes(1_000_000).b

      ranges = hasher.cdc_chunk(data)
      expected_xorb = HuggingFaceStorage::Gearhash.serialize_xorb_from_ranges(data, ranges)

      result = HuggingFaceStorage::Gearhash.full_pipeline(data, table, key, mask, min_chunk, max_chunk)
      hashes_concat, result_ranges, xorb_data = result

      expect(xorb_data).to eq(expected_xorb)
      expect(result_ranges.size).to eq(ranges.size)
    end

    it "handles 10MB data" do
      data = Random.new(99).bytes(10_000_000).b

      ranges = hasher.cdc_chunk(data)
      expected_xorb = HuggingFaceStorage::Gearhash.serialize_xorb_from_ranges(data, ranges)

      result = HuggingFaceStorage::Gearhash.full_pipeline(data, table, key, mask, min_chunk, max_chunk)
      hashes_concat, result_ranges, xorb_data = result

      expect(xorb_data).to eq(expected_xorb)
      expect(result_ranges.size).to eq(ranges.size)
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

    it "reuses the same CdcChunker instance across calls" do
      data1 = Random.new(1).bytes(100_000).b
      data2 = Random.new(2).bytes(100_000).b

      chunks1 = hasher.cdc_chunk(data1)
      chunks2 = hasher.cdc_chunk(data2)

      expect(chunks1).not_to eq(chunks2)
      expect(chunks1.size).to be > 0
      expect(chunks2.size).to be > 0
    end
  end

  describe "#cdc_and_hash_native" do
    it "produces identical ranges to cdc_chunk" do
      data = Random.bytes(1024 * 1024)
      ranges_native, _hashes_native = hasher.cdc_and_hash_native(data)
      ranges_ruby = hasher.cdc_chunk(data)
      expect(ranges_native).to eq(ranges_ruby)
    end

    it "produces identical hashes to sequential blake3_keyed" do
      data = Random.bytes(1024 * 1024)
      ranges_native, hashes_native = hasher.cdc_and_hash_native(data)

      key = described_class::DATA_KEY
      expected_hashes = ranges_native.map { |s, e| hasher.blake3_keyed(key, data.byteslice(s, e - s)) }

      hashes_array = hashes_native.scan(/.{32}/m)
      expect(hashes_array).to eq(expected_hashes)
    end

    it "handles small data (single chunk)" do
      data = ("x" * 100).b
      ranges, hashes = hasher.cdc_and_hash_native(data)
      expect(ranges).to eq([[0, 100]])
      expect(hashes.bytesize).to eq(32)
    end

    it "returns frozen strings" do
      data = Random.bytes(1024)
      _ranges, hashes = hasher.cdc_and_hash_native(data)
      expect(hashes).to be_frozen
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

    it "uses incremental path (no intermediate string allocation)" do
      hashes = [("\x01" * 32).b, ("\x02" * 32).b, ("\x03" * 32).b]
      result = hasher.compute_verification_hash(hashes)
      expected = hasher.blake3_keyed_incremental(described_class::VERIFICATION_KEY, hashes)
      expect(result).to eq(expected)
    end

    it "handles empty input" do
      result = hasher.compute_verification_hash([])
      expect(result.bytesize).to eq(32)
    end

    it "handles single hash" do
      hash = ("\x05" * 32).b
      result = hasher.compute_verification_hash([hash])
      expected = hasher.blake3_keyed_incremental(described_class::VERIFICATION_KEY, [hash])
      expect(result).to eq(expected)
    end
  end

  # ── Incremental Blake3 ──

  describe "#blake3_keyed_incremental" do
    it "produces same result as feeding concatenated data" do
      key = described_class::VERIFICATION_KEY
      chunks = [("\x01" * 32).b, ("\x02" * 32).b, ("\x03" * 32).b]
      incremental = hasher.blake3_keyed_incremental(key, chunks)
      concatenated = hasher.blake3_keyed(key, chunks.join.b)
      expect(incremental).to eq(concatenated)
    end

    it "returns 32-byte frozen string" do
      key = described_class::DATA_KEY
      result = hasher.blake3_keyed_incremental(key, ["hello".b, "world".b])
      expect(result.bytesize).to eq(32)
      expect(result).to be_frozen
    end

    it "handles single chunk" do
      key = described_class::DATA_KEY
      chunk = "single chunk data".b
      incremental = hasher.blake3_keyed_incremental(key, [chunk])
      direct = hasher.blake3_keyed(key, chunk)
      expect(incremental).to eq(direct)
    end

    it "handles empty array" do
      key = described_class::DATA_KEY
      result = hasher.blake3_keyed_incremental(key, [])
      expect(result.bytesize).to eq(32)
    end

    it "is deterministic" do
      key = described_class::DATA_KEY
      chunks = [("\xAA" * 32).b, ("\xBB" * 32).b]
      a = hasher.blake3_keyed_incremental(key, chunks)
      b = hasher.blake3_keyed_incremental(key, chunks)
      expect(a).to eq(b)
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
