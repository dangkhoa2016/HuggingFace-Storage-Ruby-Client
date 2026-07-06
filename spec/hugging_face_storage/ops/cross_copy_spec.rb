# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::FileManager::CrossCopy do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:cross_copy) { described_class.new(api_client: api_client, bucket_id: bucket_id, logger: logger) }

  describe "#copy_from" do
    it "builds batch operations and posts to API" do
      files = [{ destination: "d/f.txt", xet_hash: "abc123" }]
      expect(api_client).to receive(:batch).with(bucket_id, array_including(hash_including(type: "copyFile")),
cancel_token: nil)
      cross_copy.copy_from(source_type: "model", source_repo: "user/repo", files: files)
    end
  end
end
