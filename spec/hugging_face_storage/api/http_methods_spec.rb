# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "#get" do
    it "performs GET and returns parsed JSON" do
      stub_request(:get, "#{base}/api/buckets/#{bucket_id}")
        .with(headers: { "Authorization" => "Bearer hf_test_token" })
        .to_return(status: 200, body: '{"id":"test-bucket","size":1024}',
                   headers: { "Content-Type" => "application/json" })

      result = client.get("/api/buckets/#{bucket_id}")
      expect(result["id"]).to eq("test-bucket")
      expect(result["size"]).to eq(1024)
    end

    it "passes query parameters" do
      stub_request(:get, "#{base}/api/buckets/#{bucket_id}/tree?recursive=false")
        .to_return(status: 200, body: "[]",
                   headers: { "Content-Type" => "application/json" })

      result = client.get("/api/buckets/#{bucket_id}/tree", params: { recursive: "false" })
      expect(result).to eq([])
    end

    it "returns nil for empty body" do
      stub_request(:get, "#{base}/api/empty")
        .to_return(status: 200, body: "", headers: {})

      result = client.get("/api/empty")
      expect(result).to be_nil
    end
  end

  describe "#post" do
    it "sends JSON body" do
      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/paths-info")
        .with(
          body: '{"paths":["config.json"]}',
          headers: { "Content-Type" => "application/json" }
        )
        .to_return(status: 200, body: '[{"path":"config.json","size":660}]',
                   headers: { "Content-Type" => "application/json" })

      result = client.post("/api/buckets/#{bucket_id}/paths-info", body: { paths: ["config.json"] })
      expect(result.first["path"]).to eq("config.json")
    end
  end

  describe "#post_ndjson" do
    it "sends newline-delimited JSON" do
      ops = [
        { type: "addFile", path: "a.txt" },
        { type: "addFile", path: "b.txt" }
      ]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .with(
          body: "{\"type\":\"addFile\",\"path\":\"a.txt\"}\n{\"type\":\"addFile\",\"path\":\"b.txt\"}",
          headers: { "Content-Type" => "application/x-ndjson" }
        )
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      result = client.post_ndjson("/api/buckets/#{bucket_id}/batch", ops)
      expect(result).to eq({})
    end
  end

  describe "#put" do
    it "sends binary body" do
      stub_request(:put, "#{base}/upload/data")
        .with(body: "binary data", headers: { "Content-Type" => "application/octet-stream" })
        .to_return(status: 200, body: '{"ok":true}',
                   headers: { "Content-Type" => "application/json" })

      result = client.put("/upload/data", body: "binary data")
      expect(result["ok"]).to be true
    end
  end

  describe "#delete" do
    it "performs DELETE request" do
      stub_request(:delete, "#{base}/api/resource/123")
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      result = client.delete("/api/resource/123")
      expect(result).to eq({})
    end
  end

  describe "#head" do
    it "performs HEAD request and returns response" do
      stub_request(:head, "#{base}/api/check")
        .to_return(status: 200, headers: { "X-Custom" => "yes" })

      response = client.head("/api/check")
      expect(response.code).to eq("200")
    end
  end
end
