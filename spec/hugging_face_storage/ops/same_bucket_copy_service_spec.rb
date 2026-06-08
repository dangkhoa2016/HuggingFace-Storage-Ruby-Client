# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::SameBucketCopyService do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:post).and_return([])
      allow(a).to receive(:file_exists?).and_return(false)
    end
  end
  let(:file_manager) do
    instance_double(HuggingFaceStorage::FileManager).tap do |fm|
      allow(fm).to receive(:list).and_return([])
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:copy_pipeline) do
    instance_double(HuggingFaceStorage::CopyPipeline).tap do |cp|
      allow(cp).to receive(:execute).and_return(xet_copied: 0, files_downloaded: 0)
    end
  end

  subject(:service) do
    described_class.new(
      api_client: api, bucket_id: bucket_id, file_manager: file_manager,
      logger: logger, config: config, copy_pipeline: copy_pipeline
    )
  end

  describe "#copy_file" do
    it "copies a file within the same bucket via batch API" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(false)
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([{ "path" => "source.txt", "size" => 200, "xetHash" => "sourcehash" }])

      result = service.copy_file("source.txt", "dest.txt")
      expect(result[:from]).to eq("source.txt")
      expect(result[:to]).to eq("dest.txt")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "dest.txt", xetHash: "sourcehash",
        sourceRepoType: "bucket", sourceRepoId: bucket_id
      }], hash_including(cancel_token: nil))
    end

    it "returns early when destination exists and overwrite is false" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(true)

      result = service.copy_file("source.txt", "dest.txt", overwrite: false)
      expect(result[:from]).to eq("source.txt")
      expect(result[:to]).to eq("dest.txt")
      expect(api).not_to have_received(:batch)
    end

    it "overwrites when overwrite is true even if destination exists" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(true)
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([{ "path" => "source.txt", "size" => 200, "xetHash" => "sourcehash" }])

      result = service.copy_file("source.txt", "dest.txt", overwrite: true)
      expect(result[:to]).to eq("dest.txt")
      expect(api).to have_received(:batch)
    end

    it "forwards cancel_token to api.batch" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dst.txt").and_return(false)
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["src.txt"] }))
        .and_return([{ "path" => "src.txt", "size" => 100, "xetHash" => "h" }])

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.copy_file("src.txt", "dst.txt", cancel_token: cancel_token)
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(cancel_token: cancel_token))
    end
  end

  describe "#copy" do
    it "copies multiple files from a directory listing" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "src/a.txt", size: 100),
          HuggingFaceStorage::FileInfo.new(path: "src/b.txt", size: 200)
        ])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["src/a.txt", "src/b.txt"] }))
        .and_return([
          { "path" => "src/a.txt", "size" => 100, "xetHash" => "hash_a" },
          { "path" => "src/b.txt", "size" => 200, "xetHash" => "hash_b" }
        ])

      result = service.copy("src", "dst")
      expect(result[:from]).to eq("src")
      expect(result[:to]).to eq("dst")
      expect(copy_pipeline).to have_received(:execute)
    end

    it "raises NotFoundError when source directory is empty" do
      allow(file_manager).to receive(:list).and_return([])

      expect { service.copy("empty", "dst") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /No files found/)
    end

    it "passes cancel_token through to copy_pipeline" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["src/f.txt"] }))
        .and_return([{ "path" => "src/f.txt", "size" => 10, "xetHash" => "h1" }])

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.copy("src", "dst", cancel_token: cancel_token)
      expect(cancel_token).to have_received(:raise_if_cancelled!).at_least(:once)
    end

    it "returns a single result hash for single source" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "src/f.txt", "size" => 10, "xetHash" => "h1" }])

      result = service.copy("src", "dst")
      expect(result).to be_a(Hash)
      expect(result[:from]).to eq("src")
    end

    it "configures copy operations with bucket as sourceRepoType" do
      allow(file_manager).to receive(:list)
        .with(prefix: "models", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "models/cfg.json", size: 50)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "models/cfg.json", "size" => 50, "xetHash" => "cfg_hash" }])

      service.copy("models", "backup")

      expect(copy_pipeline).to have_received(:execute) do |args|
        expect(args[:copy_ops].first[:sourceRepoType]).to eq("bucket")
        expect(args[:copy_ops].first[:sourceRepoId]).to eq(bucket_id)
      end
    end
  end
end
