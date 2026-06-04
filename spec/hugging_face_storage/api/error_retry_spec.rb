# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "error handling" do
    it "raises AuthenticationError on 401" do
      stub_request(:get, "#{base}/api/protected")
        .to_return(status: 401, body: "Unauthorized")

      expect { client.get("/api/protected") }
        .to raise_error(HuggingFaceStorage::AuthenticationError, /Authentication failed/)
    end

    it "raises AuthenticationError on 403" do
      stub_request(:get, "#{base}/api/forbidden")
        .to_return(status: 403, body: "Forbidden")

      expect { client.get("/api/forbidden") }
        .to raise_error(HuggingFaceStorage::AuthenticationError)
    end

    it "raises NotFoundError on 404" do
      stub_request(:get, "#{base}/api/missing")
        .to_return(status: 404, body: "Not Found")

      expect { client.get("/api/missing") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /Resource not found/)
    end

    it "raises ConflictError on 409" do
      stub_request(:post, "#{base}/api/conflict")
        .to_return(status: 409, body: "Conflict")

      expect { client.post("/api/conflict") }
        .to raise_error(HuggingFaceStorage::ConflictError)
    end

    it "raises ApiError on 500 with status and body" do
      stub_request(:get, "#{base}/api/error")
        .to_return(status: 500, body: '{"error":"internal"}')

      expect { client.get("/api/error") }
        .to raise_error(HuggingFaceStorage::ApiError) { |e|
          expect(e.status).to eq(500)
          expect(e.body).to eq('{"error":"internal"}')
        }
    end

    it "uses JSON error field in error messages" do
      stub_request(:get, "#{base}/api/error-json")
        .to_return(status: 500, body: '{"error":"internal server error"}')

      expect { client.get("/api/error-json") }
        .to raise_error(HuggingFaceStorage::ApiError, /internal server error/)
    end

    it "uses JSON string body as error message" do
      stub_request(:get, "#{base}/api/error-json-string")
        .to_return(status: 500, body: '"plain json error"')

      expect { client.get("/api/error-json-string") }
        .to raise_error(HuggingFaceStorage::ApiError, /plain json error/)
    end

    it "truncates raw error bodies to 200 characters" do
      stub_request(:get, "#{base}/api/long-error")
        .to_return(status: 500, body: "x" * 300)
      expect { client.get("/api/long-error") }
        .to raise_error(HuggingFaceStorage::ApiError, /#{'x' * 200}/)
    end
  end

  describe "retry logic" do
    it "retries on retryable HTTP status" do
      stub_request(:get, "#{base}/api/flaky")
        .to_return(status: 500, body: "error").then
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })

      result = client.get("/api/flaky")
      expect(result["ok"]).to be true
    end

    it "retries on network exceptions" do
      stub_request(:get, "#{base}/api/network-error")
        .to_raise(Net::OpenTimeout).then
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })

      result = client.get("/api/network-error")
      expect(result["ok"]).to be true
    end
  end

  describe "execute_raw retry logic" do
    it "retries on retryable HTTP status in paginated requests" do
      stub_request(:get, "#{base}/api/flaky-list")
        .to_return(status: 502, body: "bad gateway").then
        .to_return(status: 200, body: '[{"id":1}]',
                   headers: { "Content-Type" => "application/json" })

      results = client.get_paginated("/api/flaky-list")
      expect(results.size).to eq(1)
    end

    it "retries on network exceptions in paginated requests" do
      stub_request(:get, "#{base}/api/net-err-list")
        .to_raise(Net::ReadTimeout).then
        .to_return(status: 200, body: '[{"id":2}]',
                   headers: { "Content-Type" => "application/json" })

      results = client.get_paginated("/api/net-err-list")
      expect(results.size).to eq(1)
    end

    it "raises after max retries exhausted in paginated requests" do
      stub_request(:get, "#{base}/api/always-fail")
        .to_return(status: 503, body: "unavailable")

      expect { client.get_paginated("/api/always-fail") }
        .to raise_error(HuggingFaceStorage::ApiError)
    end
  end

  describe "retry with cancel_token" do
    it "uses interruptible_sleep during retry when cancel_token present" do
      stub_request(:get, "#{base}/api/retry-cancel")
        .to_return(status: 500, body: "error").then
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })

      token = HuggingFaceStorage::CancelToken.new
      result = client.get("/api/retry-cancel", cancel_token: token)
      expect(result["ok"]).to be true
    end

    it "cancels during retry sleep when cancel_token is cancelled" do
      stub_request(:get, "#{base}/api/cancel-sleep")
        .to_return(status: 500, body: "error")

      token = HuggingFaceStorage::CancelToken.new
      token.cancel!

      expect { client.get("/api/cancel-sleep", cancel_token: token) }
        .to raise_error(HuggingFaceStorage::CancelledError)
    end
  end
end
