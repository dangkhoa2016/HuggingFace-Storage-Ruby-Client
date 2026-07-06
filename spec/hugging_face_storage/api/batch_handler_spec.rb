# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::BatchHandler do
  subject(:handler) { described_class.new(logger: logger, api_client: api) }

  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:config).and_return(config)
      allow(a).to receive(:build_uri).and_return(URI.parse("https://huggingface.co/api/buckets/test/batch"))
      allow(a).to receive(:execute).and_return([])
    end
  end
  let(:bucket_id) { "test-user/test-bucket" }

  describe "#batch" do
    it "returns empty BatchResult for empty operations" do
      result = handler.batch(bucket_id, [])
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(result).to be_success
      expect(result.succeeded).to be_empty
    end

    it "posts operations as NDJSON and parses success" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "status" => "ok" }])

      result = handler.batch(bucket_id, ops)
      expect(result).to be_success
      expect(result.succeeded.size).to eq(1)
    end

    it "records entry-level errors from response" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "error" => "conflict" }])

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result).not_to be_success
      expect(result.failed.size).to eq(1)
      expect(result.failed.first[:path]).to eq("dst/a.txt")
      expect(result.failed.first[:error]).to eq("conflict")
    end

    it "treats missing error field as success" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "status" => "ok" }])

      result = handler.batch(bucket_id, ops)
      expect(result.succeeded.size).to eq(1)
    end

    it "treats non-Array response as all-success with warning" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return("status" => "ok")

      result = handler.batch(bucket_id, ops)
      expect(result.succeeded.size).to eq(1)
    end

    it "raises PartialFailureError when raise_on_partial_failure is true and errors exist" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "error" => "conflict" }])

      expect { handler.batch(bucket_id, ops, raise_on_partial_failure: true) }
        .to raise_error(HuggingFaceStorage::PartialFailureError)
    end

    it "does not raise when raise_on_partial_failure is false" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "error" => "conflict" }])

      expect { handler.batch(bucket_id, ops, raise_on_partial_failure: false) }.not_to raise_error
    end

    it "handles 422 error by parsing failure body" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_raise(
        HuggingFaceStorage::ApiError.new(message: "unprocessable", status: 422,
                                                          body: JSON.generate([{ "error" => "invalid" }]))
      )

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
      expect(result.failed.first[:error]).to eq("invalid")
    end

    it "re-raises non-422 ApiError" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_raise(
        HuggingFaceStorage::ApiError.new(message: "timeout", status: 504, body: "gateway timeout")
      )

      expect { handler.batch(bucket_id, ops) }.to raise_error(HuggingFaceStorage::ApiError)
    end

    it "splits operations into slices matching batch_size" do
      ops = Array.new(5) { |i| { type: "copyFile", path: "dst/file_#{i}.txt" } }
      allow(api).to receive(:execute).and_return([{ "status" => "ok" }] * 5)

      result = handler.batch(bucket_id, ops)
      expect(result.succeeded.size).to eq(5)
    end

    it "handles response entries beyond operation count" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([
        { "status" => "ok" },
        { "error" => "unexpected" }
      ])

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.succeeded.size).to eq(1)
      expect(result.failed.size).to eq(1)
    end

    it "handles response entry with status error" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_return([{ "status" => "error", "message" => "failed" }])

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
      expect(result.failed.first[:error]).to eq("failed")
    end

    it "uses entry path or 'unknown' when path missing in failure response" do
      ops = [{ type: "copyFile" }]
      allow(api).to receive(:execute).and_return([{ "error" => "bad" }])

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.first[:path]).to eq("unknown")
    end

    it "handles 422 validation failure with non-Array body" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_raise(
        HuggingFaceStorage::ApiError.new(message: "bad request", status: 422,
                                                          body: '{"error":"invalid input"}')
      )

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
    end

    it "handles 422 validation failure with unparseable body" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_raise(
        HuggingFaceStorage::ApiError.new(message: "bad request", status: 422,
                                                          body: "not json {{{")
      )

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(1)
    end

    it "handles 422 with nil body" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      allow(api).to receive(:execute).and_raise(
        HuggingFaceStorage::ApiError.new(message: "bad request", status: 422, body: nil)
      )

      result = handler.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result.failed.size).to eq(0)
    end
  end

  describe "#post_ndjson" do
    it "sends NDJSON body with correct Content-Type" do
      ops = [{ type: "copyFile", path: "dst/a.txt" }]
      expected_body = ops.map { |op| JSON.generate(op) }.join("\n")
      allow(api).to receive(:build_uri).with("some/path").and_return(
        URI.parse("https://huggingface.co/some/path")
      )
      allow(api).to receive(:execute) do |_uri, request, cancel_token:|
        expect(request.body).to eq(expected_body)
        expect(request["Content-Type"]).to eq("application/x-ndjson")
        []
      end

      result = handler.send(:post_ndjson, "some/path", ops)
      expect(result).to eq([])
    end
  end
end
