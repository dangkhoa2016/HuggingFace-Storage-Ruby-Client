# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Notifications::Channel do
  subject(:channel) { described_class.new }

  describe "#subscribe / #publish" do
    it "notifies a subscriber of every published event" do
      events = []
      channel.subscribe { |name, payload| events << [name, payload] }

      channel.publish("upload_batch", files: 3)
      channel.publish("download_file", path: "/a")

      expect(events.size).to eq(2)
      expect(events[0]).to eq(["upload_batch", { files: 3 }])
      expect(events[1]).to eq(["download_file", { path: "/a" }])
    end

    it "supports multiple subscribers" do
      seen_a = []
      seen_b = []
      channel.subscribe { |n, _p| seen_a << n }
      channel.subscribe { |n, _p| seen_b << n }

      channel.publish("x", {})

      expect(seen_a).to eq(["x"])
      expect(seen_b).to eq(["x"])
    end

    it "does nothing when there are no subscribers" do
      expect { channel.publish("x", {}) }.not_to raise_error
    end
  end

  describe "pattern matching" do
    it "filters by String" do
      seen = []
      channel.subscribe("upload_batch") { |n, _| seen << n }
      channel.publish("upload_batch", {})
      channel.publish("download_file", {})

      expect(seen).to eq(["upload_batch"])
    end

    it "filters by Regexp" do
      seen = []
      channel.subscribe(/^upload_/) { |n, _| seen << n }
      channel.publish("upload_batch", {})
      channel.publish("upload_data", {})
      channel.publish("download_file", {})

      expect(seen).to eq(%w[upload_batch upload_data])
    end

    it "filters by Array" do
      seen = []
      channel.subscribe(%w[upload_batch download_file]) { |n, _| seen << n }
      channel.publish("upload_batch", {})
      channel.publish("upload_data", {})
      channel.publish("download_file", {})

      expect(seen).to eq(%w[upload_batch download_file])
    end

    it "raises when no block is given" do
      expect { channel.subscribe }.to raise_error(ArgumentError)
    end

    it "ignores subscribers whose pattern type is unsupported" do
      seen = []
      channel.subscribe(12_345) { |n, _| seen << n }
      channel.publish("x", {})

      expect(seen).to eq([])
    end
  end

  describe "#unsubscribe" do
    it "removes a subscriber by id" do
      seen = []
      id = channel.subscribe { |n, _| seen << n }
      channel.publish("a", {})
      channel.unsubscribe(id)
      channel.publish("b", {})

      expect(seen).to eq(["a"])
    end

    it "removes the correct subscriber when multiple exist" do
      seen_a = []
      seen_b = []
      id_a = channel.subscribe { |n, _| seen_a << n }
      channel.subscribe { |n, _| seen_b << n }

      channel.publish("a", {})
      channel.unsubscribe(id_a)
      channel.publish("b", {})

      expect(seen_a).to eq(["a"])
      expect(seen_b).to eq(%w[a b])
    end
  end

  describe "#subscribers" do
    it "returns a snapshot of current subscribers" do
      channel.subscribe("test_event") { |_n, _| nil }
      snapshot = channel.subscribers
      expect(snapshot).to be_an(Array)
      expect(snapshot.size).to eq(1)
      expect(snapshot.first[:pattern]).to eq("test_event")
    end

    it "returns a dup that does not affect internal state" do
      channel.subscribe { |_n, _| nil }
      snapshot = channel.subscribers
      snapshot.clear
      expect(channel.subscribers.size).to eq(1)
    end
  end

  describe "error isolation" do
    it "does not let one failing subscriber block others" do
      seen = []
      channel.subscribe { |_n, _| raise "boom" }
      channel.subscribe { |n, _| seen << n }

      expect { channel.publish("x", {}) }.not_to raise_error
      expect(seen).to eq(["x"])
    end
  end

  describe "#clear" do
    it "removes all subscribers" do
      channel.subscribe { |_n, _| nil }
      channel.clear
      expect(channel.subscribers).to be_empty
    end
  end

  describe "thread safety" do
    it "handles concurrent subscribe, publish, and unsubscribe without errors" do
      errors = []
      received = Queue.new

      threads = []

      threads.concat(4.times.map do
        Thread.new do
          50.times do
            id = channel.subscribe { |n, p| received << [n, p] }
            channel.publish("evt", { t: Thread.current.object_id })
            channel.unsubscribe(id)
          end
        rescue StandardError => e
          errors << e
        end
      end)

      threads.each(&:join)

      expect(errors).to be_empty
    end
  end

  describe "integration with Instrumentation" do
    it "publishes success events with elapsed time" do
      bus = described_class.new
      events = []
      bus.subscribe { |n, p| events << [n, p] }

      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(bus)
          @logger = HuggingFaceStorage::NullLogger.new
          @notifications = bus
        end

        def run
          instrument("op", foo: "bar") { 42 }
        end
      end

      result = klass.new(bus).run
      expect(result).to eq(42)
      expect(events.size).to eq(1)
      name, payload = events[0]
      expect(name).to eq("op")
      expect(payload[:foo]).to eq("bar")
      expect(payload[:status]).to eq(:success)
      expect(payload[:elapsed]).to be_a(Float).and be >= 0
    end

    it "publishes error events and re-raises" do
      bus = described_class.new
      events = []
      bus.subscribe { |n, p| events << [n, p] }

      klass = Class.new do
        include HuggingFaceStorage::Instrumentation

        def initialize(bus)
          @logger = HuggingFaceStorage::NullLogger.new
          @notifications = bus
        end

        def run
          instrument("op") { raise "fail!" }
        end
      end

      expect { klass.new(bus).run }.to raise_error("fail!")
      expect(events.size).to eq(1)
      name, payload = events[0]
      expect(name).to eq("op")
      expect(payload[:status]).to eq(:error)
      expect(payload[:error]).to be_a(RuntimeError)
    end
  end
end
