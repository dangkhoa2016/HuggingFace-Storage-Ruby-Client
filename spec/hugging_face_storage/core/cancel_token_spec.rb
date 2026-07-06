# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CancelToken do
  subject(:token) { described_class.new }

  describe "default state" do
    it "is not cancelled" do
      expect(token.cancelled?).to be false
    end
  end

  describe "#cancel!" do
    it "sets cancelled state" do
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "returns self" do
      expect(token.cancel!).to eq(token)
    end

    it "is idempotent" do
      token.cancel!
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "triggers registered callbacks" do
      fired = false
      token.on_cancel { fired = true }
      token.cancel!
      expect(fired).to be true
    end

    it "clears callbacks after firing" do
      fired = 0
      cb = -> { fired += 1 }
      token.on_cancel(&cb)
      token.cancel!
      token.cancel!
      expect(fired).to eq(1)
    end
  end

  describe "#raise_if_cancelled!" do
    it "does nothing when not cancelled" do
      expect { token.raise_if_cancelled! }.not_to raise_error
    end

    it "raises CancelledError when cancelled" do
      token.cancel!
      expect { token.raise_if_cancelled! }
        .to raise_error(HuggingFaceStorage::CancelledError, /cancelled/i)
    end
  end

  describe "#on_cancel" do
    it "returns self" do
      expect(token.on_cancel {}).to eq(token)
    end

    it "fires callback immediately if already cancelled" do
      token.cancel!
      fired = false
      token.on_cancel { fired = true }
      expect(fired).to be true
    end

    it "fires multiple callbacks in order" do
      order = []
      token.on_cancel { order << 1 }
      token.on_cancel { order << 2 }
      token.cancel!
      expect(order).to eq([1, 2])
    end

    it "logs errors from callbacks" do
      logger = instance_double(HuggingFaceStorage::NullLogger, error: nil)
      t = described_class.new(logger: logger)
      t.on_cancel { raise "oops" }
      t.cancel!
      expect(logger).to have_received(:error).with(/oops/)
    end

    it "continues to subsequent callbacks if one raises" do
      logger = instance_double(HuggingFaceStorage::NullLogger, error: nil)
      t = described_class.new(logger: logger)
      results = []
      t.on_cancel { raise "first fail" }
      t.on_cancel { results << :ok }
      t.cancel!
      expect(results).to eq([:ok])
    end

    it "does not register a callback on frozen token" do
      frozen = described_class.new.freeze
      called = false
      frozen.on_cancel { called = true }
      frozen.cancel!
      expect(called).to be false
    end

    it "logs error when callback registered after cancel raises" do
      logger = instance_double(HuggingFaceStorage::NullLogger, error: nil)
      t = described_class.new(logger: logger)
      t.cancel!
      t.on_cancel { raise "late error" }
      expect(logger).to have_received(:error).with(/late error/)
    end
  end

  describe "#cancel_subscription" do
    it "removes a previously registered callback" do
      fired = false
      cb = -> { fired = true }
      token.on_cancel(&cb)
      token.cancel_subscription(cb)
      token.cancel!
      expect(fired).to be false
    end

    it "does nothing when removing an unknown callback" do
      expect { token.cancel_subscription(-> {}) }.not_to raise_error
    end

    it "allows callback to be removed before cancellation, other callbacks still fire" do
      results = []
      cb1 = -> { results << 1 }
      cb2 = -> { results << 2 }
      token.on_cancel(&cb1)
      token.on_cancel(&cb2)
      token.cancel_subscription(cb1)
      token.cancel!
      expect(results).to eq([2])
    end
  end

  describe "thread safety" do
    it "handles concurrent cancel! and cancelled?" do
      threads = 20.times.map do
        Thread.new do
          50.times do
            token.cancel!
            token.cancelled?
          end
        end
      end
      threads.each(&:join)
      expect(token.cancelled?).to be true
    end

    it "handles concurrent on_cancel registration and cancel!" do
      fired = []
      mutex = Mutex.new
      barrier = Queue.new

      threads = 10.times.map do |i|
        Thread.new do
          barrier.push(true)
          10.times do
            token.on_cancel { mutex.synchronize { fired << i } }
          end
        end
      end

      10.times { barrier.pop }
      token.cancel!
      threads.each(&:join)
      expect(token.cancelled?).to be true
      expect(fired).not_to be_empty
    end

    it "does not fire a callback more than once" do
      call_count = 0
      mutex = Mutex.new
      cb = -> { mutex.synchronize { call_count += 1 } }
      token.on_cancel(&cb)

      threads = 5.times.map { Thread.new { token.cancel! } }
      threads.each(&:join)

      expect(call_count).to eq(1)
    end
  end

  describe "#default logger" do
    it "uses NullLogger when none provided" do
      expect(token.send(:instance_variable_get, :@logger))
        .to be_a(HuggingFaceStorage::NullLogger)
    end
  end

  describe ".none" do
    it "returns a frozen singleton" do
      expect(described_class.none).to be_frozen
      expect(described_class.none).to be(described_class.none)
    end

    it "ignores cancel!" do
      described_class.none.cancel!
      expect(described_class.none.cancelled?).to be false
    end
  end
end
