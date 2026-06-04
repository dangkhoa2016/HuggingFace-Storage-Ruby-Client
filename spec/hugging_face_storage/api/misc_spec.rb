# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "#get_xet_write_token" do
    it "extracts casUrl and accessToken" do
      stub_request(:get, "#{base}/api/buckets/#{bucket_id}/xet-write-token")
        .to_return(
          status: 200,
          body: JSON.generate(xet_write_token_response),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.get_xet_write_token(bucket_id)
      expect(result[:endpoint]).to eq(TestHelpers::CAS_URL)
      expect(result[:token]).to eq("xet_write_token_abc")
      expect(result[:expiration]).to eq(9999999999)
    end
  end

  describe "#get_xet_read_token" do
    it "extracts casUrl and accessToken" do
      stub_request(:get, "#{base}/api/buckets/#{bucket_id}/xet-read-token")
        .to_return(
          status: 200,
          body: JSON.generate(xet_read_token_response),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.get_xet_read_token(bucket_id)
      expect(result[:endpoint]).to eq(TestHelpers::CAS_URL)
      expect(result[:token]).to eq("xet_read_token_abc")
    end
  end

  describe "#list_repo_files" do
    it "lists files from repo with revision" do
      stub_request(:get, "#{base}/api/models/org/repo/tree/main/src")
        .with(query: { recursive: "true" })
        .to_return(status: 200, body: '[{"path":"src/a.rs"}]',
                   headers: { "Content-Type" => "application/json" })

      result = client.list_repo_files("model", "org/repo", path: "src", revision: "main")
      expect(result).to eq([{ "path" => "src/a.rs" }])
    end

    it "lists files without revision" do
      stub_request(:get, "#{base}/api/models/org/repo/tree")
        .with(query: { recursive: "true" })
        .to_return(status: 200, body: "[]",
                   headers: { "Content-Type" => "application/json" })

      result = client.list_repo_files("model", "org/repo")
      expect(result).to eq([])
    end
  end

  describe "Paths.encode_segments" do
    it "URI encodes each segment with %20 for spaces" do
      result = HuggingFaceStorage::Paths.encode_segments("my dir/file name.txt")
      expect(result).to eq("my%20dir/file%20name.txt")
    end
  end

  describe "request/response logging" do
    it "logs request and response at debug level" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      logging_client = described_class.new(auth: auth, logger: debug_logger)

      stub_request(:get, "#{base}/api/test")
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })

      logging_client.get("/api/test")

      log_text = output.string
      expect(log_text).to include("GET")
      expect(log_text).to include("Response: HTTP 200")
    end
  end

  describe "sensitive header masking" do
    it "does not log Authorization header (only useful headers are logged)" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      c = described_class.new(auth: auth, logger: debug_logger)

      stub_request(:get, "#{base}/api/test")
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      c.get("/api/test")
      expect(output.string).not_to include("Authorization")
      expect(output.string).not_to include("hf_test_token")
    end

    it "redacts sensitive header values in logs" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      c = described_class.new(auth: auth, logger: debug_logger)

      stub_request(:get, "#{base}/api/test")
        .to_return(status: 200, body: "{}",
                   headers: {
                     "Content-Type" => "application/json",
                     "Set-Cookie" => "secret=value123"
                   })

      stub_const("HuggingFaceStorage::RequestLogger::USEFUL_RESPONSE_HEADERS",
                 %w[content-type content-length set-cookie].freeze)

      c.get("/api/test")
      expect(output.string).to include("[REDACTED]")
      expect(output.string).not_to include("secret=value123")
    end
  end

  describe "User-Agent header" do
    it "includes library version" do
      stub_request(:get, "#{base}/api/test")
        .with(headers: { "User-Agent" => "HuggingFaceStorage-Ruby/#{HuggingFaceStorage::VERSION}" })
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      client.get("/api/test")
      expect(WebMock).to have_requested(:get, "#{base}/api/test")
        .with(headers: { "User-Agent" => "HuggingFaceStorage-Ruby/#{HuggingFaceStorage::VERSION}" })
    end
  end

  describe "#close_all_connections" do
    it "delegates to transport" do
      transport = client.instance_variable_get(:@transport)
      expect(transport).to receive(:close_all_connections)
      client.close_all_connections
    end
  end

  describe "invalid JSON response" do
    it "raises ApiError when response body is not valid JSON" do
      stub_request(:get, "#{base}/api/bad-json")
        .to_return(status: 200, body: "<<<not json>>>",
                   headers: { "Content-Type" => "text/plain" })

      expect { client.get("/api/bad-json") }.to raise_error(
        HuggingFaceStorage::ApiError,
        /Invalid JSON response/
      )
    end
  end

  describe "format_body" do
    it "truncates large bodies in logs" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      c = described_class.new(auth: auth, logger: debug_logger)
      stub_request(:get, "#{base}/api/echo")
        .to_return(status: 200, body: "x" * 3000,
                   headers: { "Content-Type" => "text/plain" })
      c.get("/api/echo", raw: true)
      expect(output.string).to include("(3000 bytes total, truncated)")
    end

    it "logs only the byte size for binary response bodies" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      c = described_class.new(auth: auth, logger: debug_logger)
      binary = "\x89PNG\r\n\x1a\n\x00\x00".b
      stub_request(:get, "#{base}/api/blob")
        .to_return(status: 200, body: binary,
                   headers: { "Content-Type" => "image/png" })
      c.get("/api/blob", raw: true)
      expect(output.string).to include("(binary, #{binary.bytesize} bytes)")
      expect(output.string).not_to include("PNG")
    end

    it "logs JSON response bodies verbatim" do
      output = StringIO.new
      debug_logger = HuggingFaceStorage::HFLogger.new(level: :debug, output: output)
      c = described_class.new(auth: auth, logger: debug_logger)
      stub_request(:get, "#{base}/api/json")
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })
      c.get("/api/json", raw: true)
      expect(output.string).to include('{"ok":true}')
    end
  end
end
