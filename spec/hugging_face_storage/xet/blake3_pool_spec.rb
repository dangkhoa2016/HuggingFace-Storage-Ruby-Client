# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Blake3Pool do
  let(:hasher) do
    instance_double(HuggingFaceStorage::XetHasher).tap do |h|
      allow(h).to receive(:blake3_keyed_with_buffers) do |buffers, key, data|
        data.b
      end
    end
  end

  subject(:pool) { described_class.new(hasher, 2) }

  after { pool.shutdown }

  describe "#map" do
    it "returns empty array for empty data" do
      expect(pool.map([], "key")).to eq([])
    end

    it "hashes each item preserving order" do
      results = pool.map(%w[a b c], "key")
      expect(results).to eq(["a".b, "b".b, "c".b])
    end

    it "works with single thread" do
      single = described_class.new(hasher, 1)
      results = single.map(%w[x y], "key")
      expect(results).to eq(["x".b, "y".b])
      single.shutdown
    end

    it "handles cancel_token" do
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      expect { pool.map(%w[a], "key", cancel_token: token) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end

    it "propagates worker errors" do
      call_count = 0
      error_hasher = Class.new do
        define_method(:blake3_keyed_with_buffers) do |_buf, _key, _data|
          raise StandardError, "worker failed"
        end
      end.new

      err_pool = described_class.new(error_hasher, 1)
      expect { err_pool.map(%w[a], "key") }
        .to raise_error(StandardError, "worker failed")
      err_pool.shutdown
    end

    it "raises TimeoutError when workers are too slow" do
      barrier = Queue.new
      slow_hasher = Class.new do
        define_method(:blake3_keyed_with_buffers) do |*|
          barrier.pop
        end
      end.new

      stub_const("HuggingFaceStorage::Blake3PoolWorker::RESULT_TIMEOUT", 0.1)

      timeout_pool = described_class.new(slow_hasher, 1)
      expect { timeout_pool.map(%w[a], "key") }
        .to raise_error(HuggingFaceStorage::TimeoutError)

      barrier.push(nil)
      timeout_pool.shutdown
    end

    it "dispatches jobs with near-zero latency" do
      timestamps = Queue.new
      instant_hasher = Class.new do
        define_method(:blake3_keyed_with_buffers) do |*_args|
          timestamps.push(Process.clock_gettime(Process::CLOCK_MONOTONIC))
          "ok"
        end
      end.new

      fast_pool = described_class.new(instant_hasher, 2)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fast_pool.map(%w[a b c d], "key")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(elapsed).to be < 0.5
      fast_pool.shutdown
    end
  end

  describe "#map (worker exception broadcast)" do
    it "propagates worker errors via result queue" do
      error_hasher = Class.new do
        define_method(:blake3_keyed_with_buffers) do |*|
          raise StandardError, "worker failed"
        end
      end.new

      err_pool = described_class.new(error_hasher, 1)
      expect { err_pool.map(%w[a], "key") }.to raise_error(StandardError, "worker failed")
    ensure
      err_pool&.shutdown
    end
  end

  describe "#shutdown" do
    it "joins all worker threads" do
      pool.shutdown
      expect(pool.size).to eq(2)
    end

    it "can be called multiple times" do
      pool.shutdown
      expect { pool.shutdown }.not_to raise_error
    end

    it "kills and wakes up threads that do not join within timeout" do
      blocker = Queue.new
      stuck_hasher = Class.new do
        define_method(:blake3_keyed_with_buffers) do |*|
          blocker.pop
        end
      end.new

      stub_const("HuggingFaceStorage::Blake3PoolWorker::RESULT_TIMEOUT", 0.1)
      stuck_pool = described_class.new(stuck_hasher, 1)
      expect { stuck_pool.map(%w[a], "key") }.to raise_error(HuggingFaceStorage::TimeoutError)
      expect { stuck_pool.shutdown }.not_to raise_error
    end
  end

  describe "#size" do
    it "returns the worker count" do
      expect(pool.size).to eq(2)
    end
  end
end
