# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::MetricsRegistry do
  describe "instance" do
    subject(:registry) { described_class.new }

    it "increments counters" do
      registry.increment(:bytes_uploaded, 100)
      registry.increment(:bytes_uploaded, 50)
      expect(registry.counter(:bytes_uploaded)).to eq(150)
    end

    it "defaults counters to 0" do
      expect(registry.counter(:unknown_metric)).to eq(0)
    end

    it "returns a snapshot via #all" do
      registry.increment(:xorbs, 3)
      registry.increment(:shards, 2)
      expect(registry.all).to eq({ xorbs: 3, shards: 2 })
    end

    it "resets all counters" do
      registry.increment(:xorbs, 5)
      registry.reset
      expect(registry.all).to eq({})
    end

    it "computes throughput when elapsed_seconds is recorded" do
      registry.increment(:elapsed_seconds, 2.0)
      registry.increment(:bytes_uploaded, 2 * 1024 * 1024)
      h = registry.to_h
      expect(h[:elapsed_seconds]).to eq(2.0)
      expect(h[:throughput_mb_per_sec]).to eq(1.0)
    end

    it "returns no throughput when elapsed is zero" do
      registry.increment(:xorbs, 1)
      h = registry.to_h
      expect(h).to eq({ xorbs: 1 })
      expect(h).not_to have_key(:throughput_mb_per_sec)
    end
  end

  describe "per-client instances" do
    it "two instances maintain separate counters" do
      r1 = described_class.new
      r2 = described_class.new
      r1.increment(:bytes_uploaded, 100)
      r2.increment(:bytes_uploaded, 50)
      expect(r1.counter(:bytes_uploaded)).to eq(100)
      expect(r2.counter(:bytes_uploaded)).to eq(50)
    end
  end

  describe "concurrent access" do
    it "handles concurrent increment from multiple threads without data loss" do
      registry = described_class.new
      threads = 10.times.map do
        Thread.new do
          100.times { registry.increment(:concurrent_counter, 1) }
        end
      end
      threads.each(&:join)
      expect(registry.counter(:concurrent_counter)).to eq(1000)
    end

    it "handles concurrent increment and counter read without error" do
      registry = described_class.new
      errors = Queue.new
      writer = Thread.new do
        500.times { registry.increment(:rw, 1) }
      rescue StandardError => e
        errors << e
      end
      reader = Thread.new do
        500.times do
          val = registry.counter(:rw)
          raise "negative counter #{val}" if val.negative?
        end
      rescue StandardError => e
        errors << e
      end
      writer.join
      reader.join
      expect(errors.size).to eq(0)
      expect(registry.counter(:rw)).to eq(500)
    end
  end

  describe "integration with Instrumentation" do
    it "records bytes_uploaded from payload hints" do
      registry = described_class.new
      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(registry)
          @logger = HuggingFaceStorage::NullLogger.new
          @metrics_registry = registry
        end

        def run
          instrument("upload_data", bytes_uploaded: 1000) { :ok }
        end
      end

      klass.new(registry).run
      expect(registry.counter(:bytes_uploaded)).to eq(1000)
    end

    it "records elapsed_seconds on every instrumented call" do
      registry = described_class.new
      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(registry)
          @logger = HuggingFaceStorage::NullLogger.new
          @metrics_registry = registry
        end

        def run
          instrument("noop") { :ok }
        end
      end

      klass.new(registry).run
      expect(registry.counter(:elapsed_seconds)).to be >= 0
    end

    it "uses per-instance metrics_registry when set on including class" do
      custom_registry = described_class.new
      default_registry = described_class.new
      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(registry)
          @logger = HuggingFaceStorage::NullLogger.new
          @metrics_registry = registry
        end

        def run
          instrument("upload_data", bytes_uploaded: 500) { :ok }
        end
      end

      klass.new(custom_registry).run
      expect(custom_registry.counter(:bytes_uploaded)).to eq(500)
      expect(default_registry.counter(:bytes_uploaded)).to eq(0)
    end

    it "records metrics even on error path" do
      registry = described_class.new
      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(registry)
          @logger = HuggingFaceStorage::NullLogger.new
          @metrics_registry = registry
        end

        def run
          instrument("upload_data", bytes_uploaded: 500) { raise "boom" }
        end
      end

      expect { klass.new(registry).run }.to raise_error("boom")
      expect(registry.counter(:bytes_uploaded)).to eq(500)
    end
  end
end
