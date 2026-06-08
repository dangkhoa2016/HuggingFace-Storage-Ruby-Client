# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CrossRepoCopyService do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:post).and_return([])
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:file_exists?).and_return(false)
    end
  end
  let(:file_manager) do
    instance_double(HuggingFaceStorage::FileManager).tap do |fm|
      allow(fm).to receive(:exists?).and_return(false)
      allow(fm).to receive(:copy_from).and_return({ files_copied: 1 })
    end
  end
  let(:copy_pipeline) do
    instance_double(HuggingFaceStorage::CopyPipeline).tap do |cp|
      allow(cp).to receive(:execute).and_return(xet_copied: 1, files_downloaded: 0)
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:source_iterator) { HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger) }

  subject(:service) do
    described_class.new(
      api_client: api, file_manager: file_manager, copy_pipeline: copy_pipeline,
      bucket_id: bucket_id, source_iterator: source_iterator, logger: logger
    )
  end

  describe "#single_copy" do
    it "copies a single file from a source repo via batch API" do
      result = service.single_copy(
        source_type: "model", source_repo: "org/my-model",
        xet_hash: "abc123def", destination: "models/weights.bin"
      )
      expect(result[:from]).to eq("model:org/my-model")
      expect(result[:to]).to eq("models/weights.bin")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/weights.bin", xetHash: "abc123def",
        sourceRepoType: "model", sourceRepoId: "org/my-model"
      }], hash_including(cancel_token: nil))
    end

    it "returns early when destination exists and overwrite is false" do
      allow(api).to receive(:file_exists?).with(bucket_id, "existing.bin").and_return(true)

      result = service.single_copy(
        source_type: "model", source_repo: "org/m",
        xet_hash: "def", destination: "existing.bin", overwrite: false
      )
      expect(result[:to]).to eq("existing.bin")
      expect(api).not_to have_received(:batch)
    end

    it "forwards cancel_token to api.batch" do
      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.single_copy(
        source_type: "dataset", source_repo: "org/data",
        xet_hash: "xyz", destination: "data.csv", cancel_token: cancel_token
      )
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(cancel_token: cancel_token))
    end

    it "includes source_path in from when provided" do
      result = service.single_copy(
        source_type: "model", source_repo: "org/m",
        xet_hash: "abc", destination: "out.bin",
        source_path: "subdir/file.bin"
      )
      expect(result[:from]).to eq("model:org/m")
    end
  end

  describe "#batch_copy" do
    it "copies multiple files from a source repo in a single batch" do
      files = [
        { xet_hash: "hash1", destination: "a.txt" },
        { xet_hash: "hash2", destination: "b.txt" }
      ]

      result = service.batch_copy(
        source_type: "bucket", source_repo: "user/other",
        files: files
      )
      expect(result[:from]).to eq("bucket:user/other")
      expect(result[:files_copied]).to eq(2)
      expect(api).to have_received(:batch) do |_bid, ops, _opts|
        expect(ops.size).to eq(2)
        expect(ops[0][:path]).to eq("a.txt")
        expect(ops[1][:path]).to eq("b.txt")
      end
    end

    it "returns zero when all files already exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", anything)
        .and_return([{ "path" => "a.txt", "type" => "file", "size" => 10 }])

      files = [{ xet_hash: "h1", destination: "a.txt" }]

      result = service.batch_copy(
        source_type: "model", source_repo: "org/r",
        files: files
      )
      expect(result[:files_copied]).to eq(0)
      expect(api).not_to have_received(:batch)
    end

    it "forwards cancel_token to api.batch" do
      files = [{ xet_hash: "h", destination: "f.txt" }]

      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.batch_copy(
        source_type: "model", source_repo: "org/r",
        files: files, cancel_token: cancel_token
      )
      expect(api).to have_received(:batch).with(bucket_id, anything,
        hash_including(cancel_token: cancel_token))
    end

    it "skips existing files when not overwriting" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", anything)
        .and_return([{ "path" => "a.txt", "type" => "file", "size" => 10 }])

      files = [
        { xet_hash: "h1", destination: "a.txt" },
        { xet_hash: "h2", destination: "b.txt" }
      ]

      result = service.batch_copy(
        source_type: "dataset", source_repo: "org/d",
        files: files
      )
      expect(result[:files_copied]).to eq(1)
      expect(api).to have_received(:batch) do |_bid, ops, _opts|
        expect(ops.size).to eq(1)
        expect(ops[0][:path]).to eq("b.txt")
      end
    end
  end

  describe "#copy_from_tree" do
    let(:tree) do
      [
        { "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "hash_c" },
        { "type" => "file", "path" => "weights.bin", "size" => 200, "xetHash" => "hash_w" }
      ]
    end

    it "copies files from a tree listing via file_manager" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree
      )
      expect(result[:files_copied]).to eq(2)
      expect(file_manager).to have_received(:copy_from)
    end

    it "filters by source_prefix" do
      prefixed_tree = [
        { "type" => "file", "path" => "config/settings.json", "size" => 100, "xetHash" => "hash_s" },
        { "type" => "file", "path" => "weights.bin", "size" => 200, "xetHash" => "hash_w" }
      ]
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: prefixed_tree,
        source_prefix: "config"
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "raises Error when no matching files found" do
      expect {
        service.copy_from_tree(
          source_type: "model", source_repo: "org/repo",
          tree: [{ "type" => "file", "path" => "f.bin", "size" => 10 }],
          source_prefix: "nonexistent"
        )
      }.to raise_error(HuggingFaceStorage::Error, /No matching files/)
    end

    it "applies exclude patterns" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree,
        exclude: "*.bin"
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "loads tree from a JSON file path" do
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, "tree.json")
        File.write(json_path, JSON.generate(tree))

        result = service.copy_from_tree(
          source_type: "model", source_repo: "org/repo", tree: json_path
        )
        expect(result[:files_copied]).to eq(2)
      end
    end

    it "uses destination_prefix when provided" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree,
        destination_prefix: "backup"
      )
      expect(result[:files_copied]).to eq(2)
    end
  end

  describe "#copy_from_repo" do
    it "copies files from a source repo using source_iterator" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: nil, revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "f.txt", "size" => 50, "xetHash" => "h1" }])
      allow(api).to receive(:post)
        .and_return([])

      result = service.copy_from_repo(
        source_type: "model", source_repo: "org/repo"
      )
      expect(result[:source]).to eq("model:org/repo")
    end

    it "supports source_path filter" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: "subdir", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "subdir/f.txt", "size" => 50, "xetHash" => "h1" }])
      allow(api).to receive(:post)
        .and_return([])

      result = service.copy_from_repo(
        source_type: "model", source_repo: "org/repo",
        source_path: "subdir", destination_prefix: "dst"
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "raises NotFoundError for non-existent repo" do
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError, "not found")

      expect {
        service.copy_from_repo(
          source_type: "model", source_repo: "org/missing"
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#copy_folders" do
    it "returns zero when folders is empty" do
      result = service.copy_folders(folders: [])
      expect(result[:folders_copied]).to eq(0)
    end

    it "copies files from multiple folders" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo-a", path: "tok", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "tok/vocab.json", "size" => 200, "xetHash" => "h1" }])
      allow(api).to receive(:list_repo_files)
        .with("dataset", "org/data-b", path: "raw", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "raw/train.csv", "size" => 300, "xetHash" => "h2" }])

      result = service.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo-a", source_path: "tok", destination: "models/a/" },
          { source_type: "dataset", source_repo: "org/data-b", source_path: "raw", destination: "data/backup/" }
        ]
      )
      expect(result[:total]).to eq(2)
    end
  end
end
