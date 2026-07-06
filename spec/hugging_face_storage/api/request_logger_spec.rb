# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::RequestLogger do
  subject(:request_logger) { described_class.new(logger: logger, config: config) }

  let(:logger) { HuggingFaceStorage::HFLogger.new(level: :debug, output: output, format: :default) }
  let(:output) { StringIO.new }
  let(:config) { HuggingFaceStorage::Configuration.new }

  def build_request(method:, headers: {}, body: nil)
    request = instance_double(Net::HTTPRequest, method: method, body: body)
    allow(request).to receive(:[]).and_return(nil)
    headers.each { |k, v| allow(request).to receive(:[]).with(k).and_return(v) }
    request
  end

  def build_response(code:, headers: {}, body: nil)
    response = instance_double(Net::HTTPResponse, code: code, body: body)
    allow(response).to receive(:[]).and_return(nil)
    allow(response).to receive(:each_header).and_yield("content-type", "application/json")
    headers.each { |k, v| allow(response).to receive(:[]).with(k).and_return(v) }
    response
  end

  let(:uri) { URI.parse("https://huggingface.co/api/buckets/test/paths") }

  describe "#log_request" do
    it "logs the HTTP method and URI" do
      request = build_request(method: "GET")
      request_logger.log_request(uri, request)
      expect(output.string).to include("GET")
      expect(output.string).to include("api/buckets/test/paths")
    end

    it "logs useful request headers" do
      request = build_request(method: "POST",
                              headers: { "content-type" => "application/json", "content-length" => "42" })
      request_logger.log_request(uri, request)
      expect(output.string).to include("content-type: application/json")
      expect(output.string).to include("content-length: 42")
    end

    it "does not log non-useful headers" do
      request = build_request(method: "GET", headers: { "x-random" => "irrelevant" })
      request_logger.log_request(uri, request)
      expect(output.string).not_to include("x-random")
    end

    context "with request body" do
      it "logs request body" do
        request = build_request(method: "POST", body: '{"key":"value"}')
        request_logger.log_request(uri, request)
        expect(output.string).to include("Request Body:")
      end

      it "does not log when body is empty" do
        request = build_request(method: "POST", body: "")
        request_logger.log_request(uri, request)
        expect(output.string).not_to include("Request Body:")
      end

      it "does not log when body is nil" do
        request = build_request(method: "POST", body: nil)
        request_logger.log_request(uri, request)
        expect(output.string).not_to include("Request Body:")
      end
    end
  end

  describe "#log_response" do
    it "logs the HTTP status code" do
      response = build_response(code: "200")
      request_logger.log_response(uri, response)
      expect(output.string).to include("Response: HTTP 200")
    end

    it "logs useful response headers" do
      response = build_response(code: "200",
                                headers: { "content-type" => "application/json", "x-request-id" => "req-123" })
      request_logger.log_response(uri, response)
      expect(output.string).to include("content-type: application/json")
      expect(output.string).to include("x-request-id: req-123")
    end

    context "with text response body" do
      it "logs the response body" do
        response = build_response(code: "200", headers: { "content-type" => "application/json" },
                                  body: '{"ok":true}')
        request_logger.log_response(uri, response)
        expect(output.string).to include("Response Body:")
        expect(output.string).to include("ok")
      end
    end

    context "with binary response body" do
      it "logs binary size instead of content" do
        response = build_response(code: "200", headers: { "content-type" => "application/octet-stream" },
                                  body: "\x00\x01\x02")
        request_logger.log_response(uri, response)
        expect(output.string).to include("binary, 3 bytes")
      end
    end

    context "with empty response body" do
      it "does not log body" do
        response = build_response(code: "204", body: nil)
        request_logger.log_response(uri, response)
        expect(output.string).not_to include("Response Body:")
      end
    end
  end

  describe "private methods" do
    describe "#mask_sensitive" do
      it "redacts sensitive headers" do
        result = request_logger.send(:mask_sensitive, "authorization", "Bearer secret")
        expect(result).to eq("[REDACTED]")
      end

      it "redacts set-cookie headers" do
        result = request_logger.send(:mask_sensitive, "set-cookie", "session=abc")
        expect(result).to eq("[REDACTED]")
      end

      it "redacts x-xet-access-token headers" do
        result = request_logger.send(:mask_sensitive, "x-xet-access-token", "tok123")
        expect(result).to eq("[REDACTED]")
      end

      it "does not redact non-sensitive headers" do
        result = request_logger.send(:mask_sensitive, "content-type", "application/json")
        expect(result).to eq("application/json")
      end

      it "is case-insensitive" do
        result = request_logger.send(:mask_sensitive, "Authorization", "secret")
        expect(result).to eq("[REDACTED]")
      end
    end

    describe "#format_body" do
      it "returns '(empty)' for nil body" do
        result = request_logger.send(:format_body, nil)
        expect(result).to eq("(empty)")
      end

      it "returns '(empty)' for empty body" do
        result = request_logger.send(:format_body, "")
        expect(result).to eq("(empty)")
      end

      it "truncates body at body_log_max" do
        log_config = HuggingFaceStorage::Configuration::LogConfig.new(body_log_max: 5)
        cfg = HuggingFaceStorage::Configuration.default.with(log: log_config)
        rl = described_class.new(logger: logger, config: cfg)
        result = rl.send(:format_body, "hello world")
        expect(result).to start_with("hello")
        expect(result).to include("truncated")
      end

      it "returns full body when under limit" do
        log_config = HuggingFaceStorage::Configuration::LogConfig.new(body_log_max: 100)
        cfg = HuggingFaceStorage::Configuration.default.with(log: log_config)
        rl = described_class.new(logger: logger, config: cfg)
        result = rl.send(:format_body, "short")
        expect(result).to eq("short")
      end
    end
  end
end
