# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ApiPaths do
  describe "operation type constants" do
    it "defines ADD_FILE" do
      expect(described_class::ADD_FILE).to eq("addFile")
    end

    it "defines DELETE_FILE" do
      expect(described_class::DELETE_FILE).to eq("deleteFile")
    end

    it "defines COPY_FILE" do
      expect(described_class::COPY_FILE).to eq("copyFile")
    end
  end

  describe "content type constants" do
    it "defines CONTENT_TYPE_NDJSON" do
      expect(described_class::CONTENT_TYPE_NDJSON).to eq("application/x-ndjson")
    end

    it "defines CONTENT_TYPE_JSON" do
      expect(described_class::CONTENT_TYPE_JSON).to eq("application/json")
    end

    it "defines CONTENT_TYPE_OCTET" do
      expect(described_class::CONTENT_TYPE_OCTET).to eq("application/octet-stream")
    end
  end

  describe "status code constants" do
    it "defines RETRYABLE_HTTP_STATUSES" do
      expect(described_class::RETRYABLE_HTTP_STATUSES).to contain_exactly(429, 500, 502, 503, 504)
    end

    it "defines REDIRECT_CODES" do
      expect(described_class::REDIRECT_CODES).to contain_exactly(301, 302, 307, 308)
    end

    it "defines Status::OK as a range" do
      expect(described_class::Status::OK).to eq(200..299)
    end

    it "defines individual status codes" do
      expect(described_class::Status::UNAUTHORIZED).to eq(401)
      expect(described_class::Status::FORBIDDEN).to eq(403)
      expect(described_class::Status::NOT_FOUND).to eq(404)
      expect(described_class::Status::CONFLICT).to eq(409)
      expect(described_class::Status::UNPROCESSABLE).to eq(422)
      expect(described_class::Status::TOO_MANY_REQUESTS).to eq(429)
    end

    it "defines Status::SERVER_ERRORS as a range" do
      expect(described_class::Status::SERVER_ERRORS).to eq(500..599)
    end
  end

  describe ".bucket_path" do
    it "builds a bucket path with parts" do
      expect(described_class.bucket_path("user/test", "batch")).to eq("/api/buckets/user/test/batch")
    end

    it "builds a bucket path without parts" do
      expect(described_class.bucket_path("user/test")).to eq("/api/buckets/user/test/")
    end
  end

  describe ".xet_token_path" do
    it "builds a xet token path" do
      expect(described_class.xet_token_path("user/test", "write")).to eq("/api/buckets/user/test/xet-write-token")
    end
  end

  describe ".paths_info_path" do
    it "builds a paths-info path" do
      expect(described_class.paths_info_path("user/test")).to eq("/api/buckets/user/test/paths-info")
    end
  end

  describe ".tree_path" do
    it "builds a tree path with a specific path" do
      expect(described_class.tree_path("user/test", "dir/file.txt")).to eq("/api/buckets/user/test/tree/dir/file.txt")
    end

    it "builds a tree path without a specific path" do
      expect(described_class.tree_path("user/test")).to eq("/api/buckets/user/test/tree")
    end
  end

  describe ".batch_path" do
    it "builds a batch path" do
      expect(described_class.batch_path("user/test")).to eq("/api/buckets/user/test/batch")
    end
  end

  describe ".repo_tree_path" do
    it "builds a repo tree path" do
      expect(described_class.repo_tree_path("model", "org/myrepo")).to eq("/api/models/org/myrepo/tree")
    end
  end

  describe ".repo_paths_info_path" do
    it "builds a repo paths-info path" do
      expect(described_class.repo_paths_info_path("dataset", "org/data")).to eq("/api/datasets/org/data/paths-info")
    end
  end
end
