# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Partial failure handling" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:client) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: null_logger) }
  let(:base) { TestHelpers::BASE_URL }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  describe "ApiClient#batch with raise_on_partial_failure: false" do
    it "returns BatchResult with failures without raising" do
      ops = [
        { type: "deleteFile", path: "a.txt" },
        { type: "deleteFile", path: "b.txt" }
      ]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(
          status: 422,
          body: JSON.generate([
            { "path" => "a.txt", "status" => "ok" },
            { "path" => "b.txt", "error" => "not found" }
          ]),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.batch(bucket_id, ops, raise_on_partial_failure: false)
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(result.success_count).to eq(1)
      expect(result.failure_count).to eq(1)
      expect(result.failed.first[:path]).to eq("b.txt")
    end

    it "raises PartialFailureError by default" do
      ops = [{ type: "deleteFile", path: "a.txt" }]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(
          status: 422,
          body: JSON.generate([{ "path" => "a.txt", "error" => "gone" }]),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.batch(bucket_id, ops) }
        .to raise_error(HuggingFaceStorage::PartialFailureError)
    end
  end

  describe "successful batch returns BatchResult" do
    it "marks all operations as succeeded" do
      ops = [
        { type: "addFile", path: "x.txt" },
        { type: "addFile", path: "y.txt" }
      ]

      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      result = client.batch(bucket_id, ops)
      expect(result.success?).to be true
      expect(result.success_count).to eq(2)
    end
  end
end
