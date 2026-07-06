# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileCopyService do
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:post).and_return(nil)
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:file_exists?).and_return(false)
    end
  end
  let(:xet_uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_batch).and_return([])
    end
  end

  let(:copy_pipeline) { HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger, config: config) }
  let(:same_bucket) { HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, logger: logger, config: config) }
  let(:source_iter) { HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger) }
  let(:cross_repo) { HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: nil, copy_pipeline: copy_pipeline, bucket_id: bucket_id, source_iterator: source_iter, logger: logger) }
  subject(:service) do
    described_class.new(same_bucket: same_bucket, cross_repo: cross_repo, copy_pipeline: copy_pipeline,
                        config: config, logger: logger)
  end

  # ── copy (same-bucket) ──

  describe "#copy" do
    it "copies a file within the same bucket" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([{ "path" => "source.txt", "size" => 200, "xetHash" => "sourcehash" }])

      result = service.copy("source.txt", "dest.txt")
      expect(result[:from]).to eq("source.txt")
      expect(result[:to]).to eq("dest.txt")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "dest.txt", xetHash: "sourcehash",
        sourceRepoType: "bucket", sourceRepoId: bucket_id
      }], hash_including(cancel_token: nil))
    end

    it "skips when destination exists and overwrite is false" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(true)

      result = service.copy("source.txt", "dest.txt", overwrite: false)
      expect(result[:from]).to eq("source.txt")
      expect(result[:to]).to eq("dest.txt")
      expect(api).not_to have_received(:batch)
    end

    it "overwrites when overwrite is true even if destination exists" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(true)
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([{ "path" => "source.txt", "size" => 200, "xetHash" => "sourcehash" }])

      result = service.copy("source.txt", "dest.txt", overwrite: true)
      expect(result[:to]).to eq("dest.txt")
      expect(api).to have_received(:batch)
    end

    it "raises NotFoundError when source does not exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([])

      expect { service.copy("source.txt", "dest.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end

    it "forwards cancel_token to api.batch" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["src.txt"] }))
        .and_return([{ "path" => "src.txt", "size" => 100, "xetHash" => "h" }])

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.copy("src.txt", "dst.txt", cancel_token: cancel_token)
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(cancel_token: cancel_token))
    end
  end

  # ── copy_from (cross-repo) ──

  describe "#copy_from" do
    it "copies a single file from another repo" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["models/config.json"] }))
        .and_return([])

      result = service.copy_from(
        source_type: "model",
        source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
        xet_hash: "3a1f858c",
        destination: "models/config.json"
      )
      expect(result[:from]).to eq("model:Qwen/Qwen2.5-0.5B-Instruct")
      expect(result[:to]).to eq("models/config.json")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/config.json", xetHash: "3a1f858c",
        sourceRepoType: "model", sourceRepoId: "Qwen/Qwen2.5-0.5B-Instruct"
      }], hash_including(cancel_token: nil))
    end

    it "copies a batch of files from another repo" do
      files = [
        { xet_hash: "hash1", destination: "a.txt" },
        { xet_hash: "hash2", destination: "b.txt" }
      ]

      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: hash_including(paths: ["a.txt", "b.txt"])))
        .and_return([])

      result = service.copy_from(
        source_type: "bucket",
        source_repo: "user/other-bucket",
        files: files
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "raises ArgumentError when xet_hash and destination are missing for single copy" do
      expect {
        service.copy_from(source_type: "model", source_repo: "repo", destination: "out.txt")
      }.to raise_error(ArgumentError, /xet_hash and destination are required/)
    end

    it "skips single copy when destination exists and overwrite is false" do
      allow(api).to receive(:file_exists?).with(bucket_id, "existing.txt").and_return(true)

      result = service.copy_from(
        source_type: "model", source_repo: "org/repo",
        xet_hash: "abc", destination: "existing.txt", overwrite: false
      )
      expect(result[:to]).to eq("existing.txt")
      expect(api).not_to have_received(:batch)
    end

    it "skips existing files in batch when overwrite is false" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: hash_including(paths: ["a.txt", "b.txt"])))
        .and_return([{ "path" => "a.txt", "type" => "file", "size" => 10 }])

      files = [
        { xet_hash: "hash1", destination: "a.txt" },
        { xet_hash: "hash2", destination: "b.txt" }
      ]

      result = service.copy_from(
        source_type: "bucket", source_repo: "user/other-bucket",
        files: files
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "forwards cancel_token to api.batch for single copy" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["dst.txt"] }))
        .and_return([])

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.copy_from(
        source_type: "dataset", source_repo: "org/data",
        xet_hash: "def", destination: "dst.txt",
        cancel_token: cancel_token
      )
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(cancel_token: cancel_token))
    end
  end

  # ── copy_file (single file, cross-repo) ──

  describe "#copy_file" do
    it "copies a single file from an external repo" do
      allow(api).to receive(:post)
        .with("/api/models/org/repo/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = service.copy_file(
        source_type: "model",
        source_repo: "org/repo",
        source_path: "weights.bin",
        destination: "models/weights.bin"
      )
      expect(result[:from]).to eq("model:org/repo/weights.bin")
      expect(result[:to]).to eq("models/weights.bin")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/weights.bin", xetHash: "hash1",
        sourceRepoType: "model", sourceRepoId: "org/repo"
      }], hash_including(cancel_token: nil))
    end

    it "appends basename when destination ends with /" do
      allow(api).to receive(:post)
        .with("/api/models/org/repo/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = service.copy_file(
        source_type: "model",
        source_repo: "org/repo",
        source_path: "weights.bin",
        destination: "models/"
      )
      expect(result[:to]).to eq("models/weights.bin")
    end

    it "supports custom revision" do
      allow(api).to receive(:post)
        .with("/api/models/org/repo/paths-info/v2", hash_including(body: { paths: ["cfg.json"] }))
        .and_return([{ "type" => "file", "path" => "cfg.json", "size" => 50, "xetHash" => "h2" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      service.copy_file(
        source_type: "model", source_repo: "org/repo",
        source_path: "cfg.json", destination: "cfg.json", revision: "v2"
      )
      expect(api).to have_received(:post)
        .with("/api/models/org/repo/paths-info/v2", anything)
    end
  end

  # ── copy_files (batch via CopyPipeline) ──

  describe "#copy_files" do
    it "returns zero counters for empty files" do
      result = service.copy_files(files: [])
      expect(result[:xet_copied]).to eq(0)
      expect(result[:files_downloaded]).to eq(0)
      expect(result[:total]).to eq(0)
      expect(result[:skipped]).to eq(0)
    end

    it "copies xet-backed files server-side" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = service.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/weights.bin"
      }])
      expect(result[:xet_copied]).to eq(1)
      expect(result[:total]).to eq(1)
    end

    it "passes on_progress to CopyPipeline" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      progress = ->(p) {}

      result = service.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/weights.bin"
      }], on_progress: progress)
      expect(result[:xet_copied]).to eq(1)
    end

    it "passes raise_on_partial_failure to CopyPipeline" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = service.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/weights.bin"
      }], raise_on_partial_failure: false)
      expect(result[:xet_copied]).to eq(1)
    end

    it "handles trailing-slash destinations" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = service.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/"
      }])
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/weights.bin", xetHash: "hash1",
        sourceRepoType: "model", sourceRepoId: "org/model"
      }], hash_including(cancel_token: nil))
    end

    it "raises Error for unmigrated LFS files" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["big.bin"] }))
        .and_return([{ "type" => "file", "path" => "big.bin", "size" => 5_000_000_000,
          "lfs" => { "oid" => "abc", "size" => 5_000_000_000, "pointerSize" => 134 } }])

      expect {
        service.copy_files(files: [{
          source_type: "model", source_repo: "org/model",
          source_path: "big.bin", destination: "models/big.bin"
        }])
      }.to raise_error(HuggingFaceStorage::Error, /LFS file/)
    end
  end
end
