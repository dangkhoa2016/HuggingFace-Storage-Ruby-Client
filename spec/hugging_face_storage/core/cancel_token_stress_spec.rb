# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CancelToken do
  subject(:token) { described_class.new(logger: null_logger) }

  describe "stress tests", :slow do
    it "stress: #cancel! during poll loop raises CancelledError via #raise_if_cancelled!" do
      queue = Queue.new
      t = Thread.new { token.cancel!; queue.push(nil) }
      queue.pop
      expect { loop { token.raise_if_cancelled! } }.to raise_error(HuggingFaceStorage::CancelledError)
      t.join(1)
    end

    it "stress: concurrent cancellation from 20 threads all succeed" do
      threads = 20.times.map { Thread.new { token.cancel! } }
      threads.each(&:join)
      expect(token.cancelled?).to be true
    end

    it "stress: #cancel! with 50 concurrent callbacks fires all of them" do
      fired = []
      mutex = Mutex.new
      50.times { |i| token.on_cancel { mutex.synchronize { fired << i } } }
      threads = 5.times.map { Thread.new { token.cancel! } }
      threads.each(&:join)
      expect(fired.sort).to eq((0...50).to_a)
    end

    it "stress: #cancel_subscription prevents callback from being called" do
      invoked = false
      cb = -> { invoked = true }
      token.on_cancel(&cb)
      token.cancel_subscription(cb)
      token.cancel!
      expect(invoked).to be false
    end

    it "stress: #cancel! is idempotent with late callbacks" do
      fired = []
      5.times { token.cancel! }
      token.on_cancel { fired << :late }
      token.cancel!
      expect(fired).to eq([:late])
    end

    it "stress: concurrent access to CancelToken.none is thread-safe" do
      threads = 10.times.map do
        Thread.new do
          50.times do
            described_class.none.cancel!
            described_class.none.cancelled?
          end
        end
      end
      threads.each(&:join)
      expect(described_class.none.cancelled?).to be false
    end

    it "stress: interleaved #cancel! and #cancelled? from 10 threads survives" do
      threads = 10.times.map do
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

    it "stress: #cancel! with callback raising still marks as cancelled" do
      token.on_cancel { raise "deliberate crash" }
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "stress: #cancel_subscription with non-existent key does not raise" do
      cb = -> {}
      expect { token.cancel_subscription(cb) }.not_to raise_error
    end

    it "stress: late #on_cancel after cancel! from multiple threads" do
      token.cancel!
      results = []
      mutex = Mutex.new
      threads = 5.times.map do |i|
        Thread.new do
          token.on_cancel { mutex.synchronize { results << i } }
        end
      end
      threads.each(&:join)
      expect(results.sort).to eq((0...5).to_a)
    end
  end
end
