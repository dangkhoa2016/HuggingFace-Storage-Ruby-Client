# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Retryable do
  subject(:instance) { described_class.new(logger: null_logger) }

  let(:config) { HuggingFaceStorage::Configuration.new }

  def http_response(code, headers: {})
    double("HTTPResponse", code: code.to_s, to_s: "HTTP #{code}").tap do |d|
      allow(d).to receive(:is_a?).with(Net::HTTPResponse).and_return(true)
      allow(d).to receive(:[]) { |k| headers[k] }
    end
  end

  describe "#retryable_http_status?" do
    it "returns true for 429" do
      expect(instance.send(:retryable_http_status?, 429)).to be true
    end

    it "returns true for 500" do
      expect(instance.send(:retryable_http_status?, 500)).to be true
    end

    it "returns true for 502" do
      expect(instance.send(:retryable_http_status?, 502)).to be true
    end

    it "returns true for 503" do
      expect(instance.send(:retryable_http_status?, 503)).to be true
    end

    it "returns true for 504" do
      expect(instance.send(:retryable_http_status?, 504)).to be true
    end

    it "returns false for 200" do
      expect(instance.send(:retryable_http_status?, 200)).to be false
    end

    it "returns false for 404" do
      expect(instance.send(:retryable_http_status?, 404)).to be false
    end

    it "returns false for 400" do
      expect(instance.send(:retryable_http_status?, 400)).to be false
    end
  end

  describe "#interruptible_sleep" do
    it "sleeps for the given seconds when no cancel token" do
      expect(instance).to receive(:sleep).with(0.01).once
      instance.interruptible_sleep(0.01, nil)
    end

    it "sleeps for the full duration when cancel token is not triggered" do
      token = HuggingFaceStorage::CancelToken.new
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      instance.interruptible_sleep(0.01, token)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be >= 0.009
    end

    it "wakes up early when cancel token is triggered" do
      token = HuggingFaceStorage::CancelToken.new
      ready = Queue.new
      t = Thread.new do
        ready.pop
        token.cancel!
      end
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ready.push(true)
      instance.interruptible_sleep(10, token)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      t.join(1)
      expect(elapsed).to be < 5
    end

    it "cancels sleep if token already cancelled" do
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      instance.interruptible_sleep(10, token)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < 1
    end
  end

  describe "#retry_with_backoff" do
    context "when no retries needed" do
      it "returns the response on success" do
        resp = http_response(200)
        result = instance.retry_with_backoff(config) { resp }
        expect(result).to be(resp)
      end

      it "does not retry on non-retryable status" do
        resp = http_response(404)
        expect(instance).not_to receive(:interruptible_sleep)
        instance.retry_with_backoff(config) { resp }
      end
    end

    context "when HTTP retry succeeds" do
      it "retries up to max_retries times then succeeds" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001)
        call_count = 0
        result = instance.retry_with_backoff(c) do
          call_count += 1
          call_count < 3 ? http_response(503) : http_response(200)
        end
        expect(result.code).to eq("200")
        expect(call_count).to eq(3)
      end
    end

    context "when HTTP retries exhausted" do
      it "returns the last response after all retries" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
        call_count = 0
        result = instance.retry_with_backoff(c) do
          call_count += 1
          http_response(503)
        end
        expect(result.code).to eq("503")
        expect(call_count).to eq(3)
      end
    end

    context "when exception retry succeeds" do
      it "retries on RETRYABLE_EXCEPTIONS then succeeds" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001)
        call_count = 0
        result = instance.retry_with_backoff(c) do
          call_count += 1
          raise Errno::ECONNRESET if call_count < 3

          http_response(200)
        end
        expect(result.code).to eq("200")
        expect(call_count).to eq(3)
      end
    end

    context "when exception retries exhausted" do
      it "raises the last exception" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
        expect do
          instance.retry_with_backoff(c) { raise Errno::ECONNRESET }
        end.to raise_error(Errno::ECONNRESET)
      end
    end

    context "when non-retryable exception" do
      it "propagates non-retryable exceptions immediately" do
        expect do
          instance.retry_with_backoff(config) { raise ArgumentError, "bad arg" }
        end.to raise_error(ArgumentError, /bad arg/)
      end
    end

    context "with cancel token" do
      it "raises CancelledError when cancelled before retry" do
        token = HuggingFaceStorage::CancelToken.new
        token.cancel!
        expect do
          instance.retry_with_backoff(config, cancel_token: token) { http_response(503) }
        end.to raise_error(HuggingFaceStorage::CancelledError)
      end

      it "stops retrying when cancelled during sleep" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 10)
        token = HuggingFaceStorage::CancelToken.new
        call_count = 0
        t = Thread.new do
          sleep 0.001 until call_count >= 1
          token.cancel!
        end
        expect do
          instance.retry_with_backoff(c, cancel_token: token) do
            call_count += 1
            http_response(503)
          end
        end.to raise_error(HuggingFaceStorage::CancelledError)
        t.join(1)
        expect(call_count).to eq(1)
      end
    end

    context "with logger" do
      it "logs retry attempts" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 1)
        out = StringIO.new
        log = HuggingFaceStorage::HFLogger.new(level: :info, output: out, format: :default)
        instance.retry_with_backoff(c, logger: log) { http_response(503) }
        expect(out.string).to include("Retry 1/1 after", "(HTTP 503)")
      end

      it "logs exception retries" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 1)
        out = StringIO.new
        log = HuggingFaceStorage::HFLogger.new(level: :info, output: out, format: :default)
        begin
          instance.retry_with_backoff(c, logger: log) { raise Errno::ECONNRESET }
        rescue StandardError
          nil
        end
        expect(out.string).to include("Retry 1/1 after", "Errno::ECONNRESET")
      end
    end

    context "with Retry-After header" do
      it "honors integer Retry-After within max_retry_delay" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 10, max_retry_delay: 1, max_retries: 1)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        instance.retry_with_backoff(c) { http_response(429, headers: { "retry-after" => "0.05" }) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        expect(elapsed).to be < 1.0
      end

      it "caps huge Retry-After at max_retry_delay" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retry_delay: 0.05, max_retries: 1)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        instance.retry_with_backoff(c) { http_response(503, headers: { "retry-after" => "3600" }) }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        expect(elapsed).to be < 1.0
      end

      it "falls back to exponential backoff when Retry-After absent" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.01, max_retry_delay: 0.05, max_retries: 1)
        result = instance.retry_with_backoff(c) { http_response(503) }
        expect(result.code.to_i).to eq(503)
      end
    end

    context "with ApiError" do
      it "retries on transient 503 ApiError and eventually succeeds" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
        call_count = 0

        result = instance.retry_with_backoff(c) do
          call_count += 1
          raise HuggingFaceStorage::ApiError.new(message: "busy", status: 503) if call_count < 3

          http_response(200)
        end

        expect(result.code).to eq("200")
        expect(call_count).to eq(3)
      end

      it "does not retry on non-transient 404 ApiError" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
        call_count = 0

        expect do
          instance.retry_with_backoff(c) do
            call_count += 1
            raise HuggingFaceStorage::ApiError.new(message: "not found", status: 404)
          end
        end.to raise_error(HuggingFaceStorage::ApiError)

        expect(call_count).to eq(1)
      end

      it "does not retry on 400 Bad Request" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
        call_count = 0

        expect do
          instance.retry_with_backoff(c) do
            call_count += 1
            raise HuggingFaceStorage::ApiError.new(message: "bad", status: 400)
          end
        end.to raise_error(HuggingFaceStorage::ApiError)

        expect(call_count).to eq(1)
      end

      it "gives up after max_retries on persistent 503 ApiError" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
        call_count = 0

        expect do
          instance.retry_with_backoff(c) do
            call_count += 1
            raise HuggingFaceStorage::ApiError.new(message: "busy", status: 503)
          end
        end.to raise_error(HuggingFaceStorage::ApiError)

        expect(call_count).to eq(3)
      end
    end

    context "with retry_count passed to block" do
      it "passes the current retry count to the block" do
        c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
        counts = []
        instance.retry_with_backoff(c) do |retry_count|
          counts << retry_count
          http_response(503)
        end
        expect(counts).to eq([0, 1, 2])
      end
    end
  end

  describe "#retryable_api_error?" do
    it "returns true for transient status codes" do
      [429, 500, 502, 503, 504].each do |code|
        err = HuggingFaceStorage::ApiError.new(message: "x", status: code)
        expect(instance.send(:retryable_api_error?, err)).to be(true)
      end
    end

    it "returns false for non-transient status codes" do
      [400, 401, 403, 404, 409, 422].each do |code|
        err = HuggingFaceStorage::ApiError.new(message: "x", status: code)
        expect(instance.send(:retryable_api_error?, err)).to be(false)
      end
    end

    it "returns false for non-ApiError" do
      expect(instance.send(:retryable_api_error?, RuntimeError.new("x"))).to be(false)
    end
  end

  describe "#handle_retry_error" do
    it "re-raises non-retryable, non-ApiError exceptions immediately" do
      error = StandardError.new("something broke")
      expect do
        instance.send(:handle_retry_error, error, 0, config, nil, nil)
      end.to raise_error(StandardError, "something broke")
    end
  end

  describe "RETRYABLE_EXCEPTIONS" do
    it "includes expected exception classes" do
      expect(HuggingFaceStorage::Retryable::RETRYABLE_EXCEPTIONS)
        .to include(Errno::ECONNRESET, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout)
    end
  end

  describe "#parse_retry_after" do
    it "returns nil for nil/empty" do
      expect(instance.send(:parse_retry_after, nil)).to be_nil
      expect(instance.send(:parse_retry_after, "")).to be_nil
    end

    it "parses integer seconds" do
      expect(instance.send(:parse_retry_after, "42")).to eq(42)
      expect(instance.send(:parse_retry_after, "0")).to eq(0)
    end

    it "parses float seconds" do
      expect(instance.send(:parse_retry_after, "0.5")).to be_within(0.001).of(0.5)
      expect(instance.send(:parse_retry_after, "1.25")).to be_within(0.001).of(1.25)
    end

    it "parses HTTP-date" do
      future = (Time.now + 5).httpdate
      delay = instance.send(:parse_retry_after, future)
      expect(delay).to be_within(1.5).of(5)
    end

    it "returns 0 for past HTTP-date" do
      past = (Time.now - 60).httpdate
      expect(instance.send(:parse_retry_after, past)).to eq(0)
    end

    it "returns nil for garbage" do
      expect(instance.send(:parse_retry_after, "not a number or date")).to be_nil
    end
  end
end

RSpec.describe "Retry with cancel token" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:client) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: null_logger) }
  let(:base) { TestHelpers::BASE_URL }
  let!(:cancel_thread) { [] }

  after {
    cancel_thread.each { |t|
      begin
        t.join(1)
      rescue StandardError
        nil
      end
    }
  }

  it "stops retrying when cancel token is triggered during sleep", :slow do
    token = HuggingFaceStorage::CancelToken.new

    @request_made = false
    stub_request(:get, "#{base}/api/test")
      .to_return do |_req|
        @request_made = true
        { status: 503, body: "service unavailable" }
      end

    cancel_thread << Thread.new do
      sleep 0.001 until @request_made
      token.cancel!
    end

    expect {
      client.get("/api/test", cancel_token: token)
    }.to raise_error(HuggingFaceStorage::CancelledError)
  end

  it "checks cancel token before each retry attempt" do
    token = HuggingFaceStorage::CancelToken.new
    token.cancel!

    expect {
      client.get("/api/test", cancel_token: token)
    }.to raise_error(HuggingFaceStorage::CancelledError)
  end
end
