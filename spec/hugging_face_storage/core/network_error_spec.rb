# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Retryable do
  subject(:instance) { described_class.new(logger: null_logger) }

  def http_response(code, headers: {})
    double("HTTPResponse", code: code.to_s, to_s: "HTTP #{code}").tap do |d|
      allow(d).to receive(:is_a?).with(Net::HTTPResponse).and_return(true)
      allow(d).to receive(:[]) { |k| headers[k] }
    end
  end

  describe "network error retry behavior" do
    it "network: retries on Errno::ECONNREFUSED" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
      call_count = 0
      result = instance.retry_with_backoff(c) do
        call_count += 1
        raise Errno::ECONNREFUSED if call_count < 3

        http_response(200)
      end
      expect(result.code).to eq("200")
      expect(call_count).to eq(3)
    end

    it "network: retries on Net::OpenTimeout" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
      call_count = 0
      result = instance.retry_with_backoff(c) do
        call_count += 1
        raise Net::OpenTimeout if call_count < 3

        http_response(200)
      end
      expect(result.code).to eq("200")
      expect(call_count).to eq(3)
    end

    it "network: stops on SocketError (not retryable)" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise SocketError
        end
      end.to raise_error(SocketError)
      expect(call_count).to eq(1)
    end

    it "network: stops on ArgumentError (not retryable)" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise ArgumentError, "bad arg"
        end
      end.to raise_error(ArgumentError)
      expect(call_count).to eq(1)
    end

    it "network: respects max_retries = 0 (no retries at all)" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 0)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise Errno::ECONNREFUSED
        end
      end.to raise_error(Errno::ECONNREFUSED)
      expect(call_count).to eq(1)
    end

    it "network: respects max_retries = 1 (only one retry attempt)" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 1)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise Errno::ECONNRESET
        end
      end.to raise_error(Errno::ECONNRESET)
      expect(call_count).to eq(2)
    end

    it "network: passes correct retry count to block" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 3)
      counts = []
      instance.retry_with_backoff(c) do |retry_count|
        counts << retry_count
        raise Errno::ECONNRESET if retry_count < 2

        http_response(200)
      end
      expect(counts).to eq([0, 1, 2])
    end

    it "network: retries on mixed error types across attempts" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 4)
      call_count = 0
      result = instance.retry_with_backoff(c) do
        call_count += 1
        case call_count
        when 1 then raise Errno::ECONNRESET
        when 2 then raise Net::OpenTimeout
        when 3 then raise Errno::ECONNREFUSED
        when 4 then raise Net::ReadTimeout
        else http_response(200)
        end
      end
      expect(result.code).to eq("200")
      expect(call_count).to eq(5)
    end

    it "network: raises ECONNREFUSED after max_retries exhausted" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise Errno::ECONNREFUSED
        end
      end.to raise_error(Errno::ECONNREFUSED)
      expect(call_count).to eq(3)
    end

    it "network: raises Net::OpenTimeout after max_retries exhausted" do
      c = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retries: 2)
      call_count = 0
      expect do
        instance.retry_with_backoff(c) do
          call_count += 1
          raise Net::OpenTimeout
        end
      end.to raise_error(Net::OpenTimeout)
      expect(call_count).to eq(3)
    end
  end
end
