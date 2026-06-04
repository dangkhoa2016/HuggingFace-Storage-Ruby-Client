# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiClient, "#file_exists?" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:client) { described_class.new(auth: auth, logger: null_logger) }
  let(:base) { TestHelpers::BASE_URL }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  it "returns true when HEAD resolve succeeds" do
    stub_request(:head, "#{base}/buckets/#{bucket_id}/resolve/readme.txt")
      .to_return(status: 200)

    expect(client.file_exists?(bucket_id, "readme.txt")).to be true
  end

  it "returns false when HEAD resolve returns 404" do
    stub_request(:head, "#{base}/buckets/#{bucket_id}/resolve/missing.txt")
      .to_return(status: 404, body: "not found")

    expect(client.file_exists?(bucket_id, "missing.txt")).to be false
  end

  it "encodes path segments" do
    stub_request(:head, "#{base}/buckets/#{bucket_id}/resolve/models/my%20model.bin")
      .to_return(status: 200)

    expect(client.file_exists?(bucket_id, "models/my model.bin")).to be true
  end
end
