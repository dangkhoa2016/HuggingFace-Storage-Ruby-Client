# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::HTTPTransport do
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:logger) { null_logger }
  let(:http) { instance_double(Net::HTTP) }
  let(:http_pool) { instance_double(HuggingFaceStorage::HttpPool) }
  let(:retryable) { instance_double(HuggingFaceStorage::Retryable) }
  let(:request_logger) { double("request_logger") }
  let(:redirect_follower) { double("redirect_follower", follow_redirects: nil) }

  subject(:transport) { described_class.new(config: config, logger: logger) }

  before do
    allow(HuggingFaceStorage::HttpPool).to receive(:new).and_return(http_pool)
    allow(HuggingFaceStorage::Retryable).to receive(:new).and_return(retryable)
    allow(HuggingFaceStorage::RequestLogger).to receive(:new).and_return(request_logger)
    allow(HuggingFaceStorage::RedirectFollower).to receive(:new).and_return(redirect_follower)
    allow(request_logger).to receive(:log_request)
    allow(request_logger).to receive(:log_response)
  end

  def stub_successful_http_response(body: "{}", code: "200")
    response = instance_double(Net::HTTPResponse, body: body, code: code)
    allow(response).to receive(:[]).with("content-type").and_return("application/json")
    allow(response).to receive(:each_header).and_yield("content-type", "application/json")

    allow(retryable).to receive(:retry_with_backoff).and_yield(0).and_return(response)
    allow(http_pool).to receive(:with_connection).and_yield(http)
    allow(http).to receive(:request).and_return(response)

    response
  end

  describe "#request" do
    it "performs a GET request and returns the body" do
      stub_successful_http_response(body: '{"ok":true}')

      result = transport.request(:get, "/api/test")
      expect(result).to eq('{"ok":true}')
    end

    it "performs a POST request with headers and body" do
      response = stub_successful_http_response(body: "created", code: "201")

      result = transport.request(:post, "/api/data", headers: { "X-Custom" => "val" }, body: "payload")
      expect(result).to eq("created")
    end

    it "builds full URI when path is an absolute URL" do
      stub_successful_http_response(body: "ok")

      result = transport.request(:get, "https://other.example.com/path")
      expect(result).to eq("ok")
    end

    it "includes query parameters" do
      stub_successful_http_response(body: "ok")

      transport.request(:get, "/api/search", query: { q: "test", limit: 10 })
      expect(request_logger).to have_received(:log_request).with(anything, kind_of(Net::HTTPRequest))
    end

    it "raises on HTTP error status" do
      allow(retryable).to receive(:retry_with_backoff).and_raise(HuggingFaceStorage::NotFoundError, "404")

      expect { transport.request(:get, "/missing") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#head" do
    it "performs a HEAD request and returns the response" do
      response = instance_double(Net::HTTPResponse, body: nil, code: "200")
      allow(response).to receive(:[]).with("content-type").and_return("text/plain")
      allow(response).to receive(:each_header).and_yield("content-type", "text/plain")

      allow(retryable).to receive(:retry_with_backoff).and_yield(0).and_return(response)
      allow(http_pool).to receive(:with_connection).and_yield(http)
      allow(http).to receive(:request).and_return(response)

      result = transport.head("/api/health")
      expect(result).to be(response)
    end

    it "raises NotFoundError for 404" do
      allow(retryable).to receive(:retry_with_backoff).and_raise(HuggingFaceStorage::NotFoundError, "404")

      expect { transport.head("/missing") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#close_all_connections" do
    it "delegates to http_pool" do
      allow(http_pool).to receive(:close_all_connections)

      transport.close_all_connections

      expect(http_pool).to have_received(:close_all_connections)
    end
  end

  describe "#build_redirect_follower" do
    it "creates a RedirectFollower with the http_pool" do
      allow(HuggingFaceStorage::RedirectFollower).to receive(:new).and_call_original

      follower = transport.build_redirect_follower
      expect(follower).to be_a(HuggingFaceStorage::RedirectFollower)
    end
  end

  describe "#stream_download" do
    it "yields response body chunks via redirect following" do
      allow(retryable).to receive(:retry_with_backoff).with(config,
hash_including(cancel_token: nil, logger: logger)).and_yield(0).and_return(nil)
      allow(redirect_follower).to receive(:follow_redirects) do |uri, req, cancel_token: nil, streaming: false, &block|
        block.call("chunk1")
        block.call("chunk2")
      end

      chunks = []
      transport.stream_download(:get, "/api/data") { |c| chunks << c }
      expect(chunks).to eq(%w[chunk1 chunk2])
    end

    it "cancels on cancel_token" do
      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!).and_raise(HuggingFaceStorage::CancelledError)
      allow(retryable).to receive(:retry_with_backoff).with(config,
hash_including(cancel_token: cancel_token, logger: logger)).and_yield(0).and_return(nil)

      expect { transport.stream_download(:get, "/api/data", cancel_token: cancel_token) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end
  end

  describe "#with_connection" do
    it "delegates to http_pool.with_connection" do
      allow(http_pool).to receive(:with_connection).and_yield(http).and_return("result")

      result = transport.with_connection(URI.parse("https://example.com")) { |conn| conn }
      expect(result).to eq("result")
      expect(http_pool).to have_received(:with_connection).with(URI.parse("https://example.com"))
    end
  end

  describe "#retry_with_backoff" do
    it "delegates to retryable" do
      allow(retryable).to receive(:retry_with_backoff).and_return("ok")

      result = transport.retry_with_backoff(config, cancel_token: nil, logger: logger) { "hello" }
      expect(result).to eq("ok")
      expect(retryable).to have_received(:retry_with_backoff).with(config, cancel_token: nil, logger: logger)
    end
  end

  describe "#log_request and #log_response" do
    it "delegates log_request to request_logger" do
      uri = URI.parse("https://example.com")
      req = Net::HTTP::Get.new(uri)
      allow(request_logger).to receive(:log_request)

      transport.log_request(uri, req)

      expect(request_logger).to have_received(:log_request).with(uri, req)
    end

    it "delegates log_response to request_logger" do
      uri = URI.parse("https://example.com")
      resp = instance_double(Net::HTTPResponse)
      allow(request_logger).to receive(:log_response)

      transport.log_response(uri, resp)

      expect(request_logger).to have_received(:log_response).with(uri, resp)
    end
  end

  describe "HTTP method variants" do
    it "performs PUT request" do
      stub_successful_http_response(body: "updated", code: "200")

      result = transport.request(:put, "/api/resource", body: '{"key":"val"}')
      expect(result).to eq("updated")
    end

    it "performs DELETE request" do
      stub_successful_http_response(body: "deleted", code: "200")

      result = transport.request(:delete, "/api/resource")
      expect(result).to eq("deleted")
    end

    it "raises ArgumentError for unknown method" do
      expect { transport.send(:build_http_request, :patch, URI.parse("https://example.com"), {}, nil) }
        .to raise_error(ArgumentError, /Unknown HTTP method/)
    end
  end

  describe "nil response handling" do
    it "raises when retryable returns nil" do
      allow(retryable).to receive(:retry_with_backoff).and_yield(0).and_return(nil)
      allow(http_pool).to receive(:with_connection).and_yield(http)
      allow(http).to receive(:request).and_return(nil)
      allow(request_logger).to receive(:log_request)
      allow(request_logger).to receive(:log_response)

      expect { transport.request(:get, "/api/test") }
        .to raise_error(RuntimeError, /unexpected nil response/)
    end
  end

  describe "private build_headers" do
    it "adds Content-Type when not present" do
      result = transport.send(:build_headers, { "X-Custom" => "val" })
      expect(result).to include("Content-Type" => "application/json", "X-Custom" => "val")
    end

    it "does not override existing Content-Type" do
      result = transport.send(:build_headers, { "Content-Type" => "text/plain" })
      expect(result["Content-Type"]).to eq("text/plain")
    end

    it "adds default Content-Type when no extra headers" do
      result = transport.send(:build_headers, {})
      expect(result).to eq({ "Content-Type" => "application/json" })
    end
  end
end
