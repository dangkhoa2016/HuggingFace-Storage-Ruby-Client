# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::HttpErrorHandler do
  def mock_response(code, body = nil, headers: {})
    response = instance_double(Net::HTTPResponse, code: code.to_s, body: body)
    allow(response).to receive(:[]).and_return(nil)
    headers.each { |k, v| allow(response).to receive(:[]).with(k).and_return(v) }
    response
  end

  describe ".raise_for_status!" do
    it "returns nil for 2xx status codes" do
      response = mock_response(200)
      expect(described_class.raise_for_status!(response)).to be_nil
    end

    it "raises AuthenticationError for 401" do
      response = mock_response(401, '{"error":"unauthorized"}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::AuthenticationError, /401/)
    end

    it "raises AuthenticationError for 403" do
      response = mock_response(403, '{"error":"forbidden"}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::AuthenticationError, /403/)
    end

    it "raises NotFoundError for 404" do
      response = mock_response(404, '{"error":"not found"}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::NotFoundError, /404/)
    end

    it "raises ConflictError for 409" do
      response = mock_response(409, '{"error":"conflict"}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::ConflictError, /409/)
    end

    it "raises ValidationError for 422" do
      response = mock_response(422, '{"error":"invalid","errors":{"field":"required"}}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::ValidationError) do |e|
          expect(e.errors).to eq({ "field" => "required" })
          expect(e.status).to eq(422)
        end
    end

    it "raises RateLimitError for 429" do
      response = mock_response(429, '{"error":"rate limited"}', headers: { "Retry-After" => "30" })
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::RateLimitError) do |e|
          expect(e.retry_after).to eq(30)
          expect(e.status).to eq(429)
        end
    end

    it "raises ApiError for other non-2xx codes" do
      response = mock_response(500, '{"error":"server error"}')
      expect { described_class.raise_for_status!(response) }
        .to raise_error(HuggingFaceStorage::ApiError) do |e|
          expect(e.status).to eq(500)
        end
    end
  end

  describe ".extract_error_message" do
    it "extracts error from JSON body with error key" do
      response = mock_response(400, '{"error":"bad request"}')
      expect(described_class.extract_error_message(response)).to eq("bad request")
    end

    it "extracts error from JSON body with message key" do
      response = mock_response(400, '{"message":"not found"}')
      expect(described_class.extract_error_message(response)).to eq("not found")
    end

    it "returns HTTP code when body is nil" do
      response = mock_response(404, nil)
      expect(described_class.extract_error_message(response)).to eq("HTTP 404")
    end

    it "returns HTTP code when body is empty" do
      response = mock_response(404, "")
      expect(described_class.extract_error_message(response)).to eq("HTTP 404")
    end

    it "truncates body to 200 chars when JSON parsing fails" do
      body = "x" * 300
      response = mock_response(400, body)
      expect(described_class.extract_error_message(response).length).to eq(200)
    end

    it "handles body that is already a JSON string" do
      response = mock_response(400, '"just a string"')
      expect(described_class.extract_error_message(response)).to eq("just a string")
    end
  end

  describe ".parse_validation_errors" do
    it "extracts errors from JSON body" do
      body = '{"error":"invalid","errors":{"name":"required","age":"must be positive"}}'
      result = described_class.parse_validation_errors(body)
      expect(result).to eq({ "name" => "required", "age" => "must be positive" })
    end

    it "returns hash body when no errors key present" do
      body = '{"field":"required"}'
      result = described_class.parse_validation_errors(body)
      expect(result).to eq({ "field" => "required" })
    end

    it "returns empty hash for nil body" do
      expect(described_class.parse_validation_errors(nil)).to eq({})
    end

    it "returns empty hash for empty body" do
      expect(described_class.parse_validation_errors("")).to eq({})
    end

    it "returns empty hash for invalid JSON" do
      expect(described_class.parse_validation_errors("not json")).to eq({})
    end
  end
end
