# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient do
  include_context "with null logger"
  include_context "with api client setup"

  describe "#batch" do
    it "does nothing for empty operations" do
      result = client.batch(bucket_id, [])
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(result).to be_success
      expect(result).to be_empty
    end

    it "sends operations as NDJSON" do
      ops = [{ type: "deleteFile", path: "old.txt" }]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      expect { client.batch(bucket_id, ops) }.not_to raise_error
    end

    it "splits large batches into chunks of BATCH_SIZE" do
      ops = (1..1500).map { |i| { type: "addFile", path: "file#{i}.txt" } }

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      client.batch(bucket_id, ops)

      expect(WebMock).to have_requested(:post, "#{base}/api/buckets/#{bucket_id}/batch").times(2)
    end

    it "re-raises non-422 ApiError" do
      ops = [{ type: "addFile", path: "test.txt" }]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 500, body: "server error")

      expect { client.batch(bucket_id, ops) }
        .to raise_error(HuggingFaceStorage::ApiError)
    end

    it "parses Array response with success and error entries" do
      ops = [
        { type: "deleteFile", path: "a.txt" },
        { type: "deleteFile", path: "b.txt" },
        { type: "deleteFile", path: "c.txt" }
      ]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(
          status: 200,
          body: JSON.generate([
            { "path" => "a.txt", "status" => "ok" },
            { "path" => "b.txt", "error" => "not found" },
            { "path" => "c.txt", "status" => "ok" }
          ]),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.success_count).to eq(2)
      expect(result.failure_count).to eq(1)
      expect(result.failed.first[:path]).to eq("b.txt")
    end
  end

  describe "batch partial failures" do
    let(:batch_stub) { "#{base}/api/buckets/#{bucket_id}/batch" }

    it "parses array response with errors via batch API" do
      stub_request(:post, batch_stub)
        .to_return(status: 422, body: '[{"error":"exists"},{"status":"ok"}]',
                   headers: { "Content-Type" => "application/json" })
      result = client.batch(bucket_id, [{ path: "a.txt" }, { path: "b.txt" }], raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
      expect(result.failed[0][:path]).to eq("a.txt")
    end

    it "handles non-array response via batch API" do
      stub_request(:post, batch_stub)
        .to_return(status: 422, body: "server error",
                   headers: { "Content-Type" => "application/json" })
      result = client.batch(bucket_id, [{ path: "a.txt" }], raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
    end

    it "handles JSON parse error via batch API" do
      stub_request(:post, batch_stub)
        .to_return(status: 422, body: "invalid json {{{",
                   headers: { "Content-Type" => "application/json" })
      result = client.batch(bucket_id, [{ path: "a.txt" }], raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
    end

    it "handles nil body via batch API" do
      stub_request(:post, batch_stub)
        .to_return(status: 422, body: nil,
                   headers: { "Content-Type" => "application/json" })
      result = client.batch(bucket_id, [], raise_on_partial_failure: false)
      expect(result.failed).to be_empty
    end
  end

  describe "batch with non-array JSON partial failure" do
    it "marks all operations as failed" do
      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 422, body: '{"error":"partial failure"}',
                   headers: { "Content-Type" => "application/json" })
      result = client.batch(bucket_id, [{ path: "a.txt" }, { path: "b.txt" }], raise_on_partial_failure: false)
      expect(result.failed.size).to eq(2)
    end
  end

  describe "batch with 422 partial failure" do
    it "parses partial failures from 422 response" do
      ops = [
        { type: "addFile", path: "a.txt" },
        { type: "addFile", path: "b.txt" }
      ]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 422,
                   body: '[{"status":"ok"},{"error":"conflict"}]',
                   headers: { "Content-Type" => "application/json" })

      result = client.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
      expect(result.succeeded.size).to eq(1)
    end
  end
end
