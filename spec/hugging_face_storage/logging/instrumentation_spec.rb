# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Instrumentation do
  let(:logger) { null_logger }
  let(:metrics_registry) { instance_double(HuggingFaceStorage::MetricsRegistry) }
  let(:notifications) { instance_double(HuggingFaceStorage::Notifications::Channel) }
  let(:null_registry) { HuggingFaceStorage::NullMetricsRegistry.new }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::Instrumentation

      def initialize(logger, metrics_registry, notifications)
        @logger = logger
        @metrics_registry = metrics_registry
        @notifications = notifications
      end

      def instrumented_call(name, payload = {})
        instrument(name, payload) { 42 }
      end

      def failing_call(name, payload = {})
        instrument(name, payload) { raise "boom" }
      end
    end
  end

  subject(:instance) { test_class.new(logger, metrics_registry, notifications) }

  before do
    allow(metrics_registry).to receive(:increment)
    allow(notifications).to receive(:publish)
  end

  describe "#instrument" do
    it "returns the block result" do
      result = instance.instrumented_call("op")
      expect(result).to eq(42)
    end

    it "records elapsed_seconds metric" do
      instance.instrumented_call("op")
      expect(metrics_registry).to have_received(:increment).with(:elapsed_seconds, kind_of(Float))
    end

    it "records metric counters from the payload" do
      instance.instrumented_call("upload", bytes_uploaded: 1024, files: 3)
      expect(metrics_registry).to have_received(:increment).with(:bytes_uploaded, 1024)
      expect(metrics_registry).to have_received(:increment).with(:files, 3)
    end

    it "publishes a success notification with elapsed time" do
      instance.instrumented_call("download")

      expect(notifications).to have_received(:publish) do |name, payload|
        expect(name).to eq("download")
        expect(payload[:status]).to eq(:success)
        expect(payload[:elapsed]).to be_a(Float).and be >= 0
      end
    end

    it "publishes an error notification and re-raises" do
      expect { instance.failing_call("op") }.to raise_error("boom")

      expect(notifications).to have_received(:publish) do |name, payload|
        expect(name).to eq("op")
        expect(payload[:status]).to eq(:error)
        expect(payload[:error]).to be_a(RuntimeError)
      end
    end

    it "records metrics even when the block raises" do
      expect { instance.failing_call("op", bytes_downloaded: 512) }.to raise_error("boom")

      expect(metrics_registry).to have_received(:increment).with(:elapsed_seconds, kind_of(Float))
      expect(metrics_registry).to have_received(:increment).with(:bytes_downloaded, 512)
    end

    it "records zero as a valid metric value" do
      instance.instrumented_call("op", bytes_uploaded: 0)
      expect(metrics_registry).to have_received(:increment).with(:bytes_uploaded, 0)
    end

    it "does not record missing metric keys" do
      instance.instrumented_call("op", custom_key: 100)
      expect(metrics_registry).to have_received(:increment).with(:elapsed_seconds, kind_of(Float))
      expect(metrics_registry).not_to have_received(:increment).with(:custom_key, anything)
    end
  end

  describe "#track_increment" do
    it "increments a metric with tags" do
      allow(metrics_registry).to receive(:increment)

      instance.track_increment(:files_uploaded, tags: { type: "model" }, by: 2)

      expect(metrics_registry).to have_received(:increment)
        .with(:files_uploaded, tags: { type: "model" }, by: 2)
    end

    it "defaults to incrementing by 1" do
      allow(metrics_registry).to receive(:increment)

      instance.track_increment(:operations)

      expect(metrics_registry).to have_received(:increment)
        .with(:operations, tags: {}, by: 1)
    end
  end

  describe "#track_gauge" do
    it "records a gauge value" do
      inst = test_class.new(logger, null_registry, notifications)

      expect { inst.track_gauge(:active_connections, 5, tags: { host: "example.com" }) }
        .not_to raise_error
    end
  end

  describe "#track_measure" do
    it "delegates to metrics_registry.measure" do
      inst = test_class.new(logger, null_registry, notifications)

      result = inst.track_measure(:request_duration) { "result" }
      expect(result).to eq("result")
    end
  end

  describe "#publish" do
    it "publishes an event to notifications" do
      instance.publish("custom_event", key: "value")

      expect(notifications).to have_received(:publish).with("custom_event", key: "value")
    end
  end

  describe "METRIC_KEYS" do
    it "includes the expected metric names" do
      expect(described_class::METRIC_KEYS).to match_array(%i[
        bytes_uploaded bytes_downloaded files xorbs shards operations
      ])
    end
  end

  describe "default null objects" do
    it "uses NullLogger when @logger is not set" do
      klass = Class.new do
        include HuggingFaceStorage::Instrumentation
      end
      instance = klass.new
      expect(instance.instance_variable_get(:@logger)).to be_a(HuggingFaceStorage::NullLogger)
      expect(instance.instance_variable_get(:@metrics_registry)).to be_a(HuggingFaceStorage::NullMetricsRegistry)
      expect(instance.instance_variable_get(:@notifications)).to be_a(HuggingFaceStorage::NullNotifications)
    end
  end
end
