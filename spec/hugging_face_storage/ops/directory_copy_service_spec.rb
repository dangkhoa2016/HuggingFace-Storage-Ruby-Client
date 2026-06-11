# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryCopyService do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:get_paginated).and_return([])
      allow(a).to receive(:head).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      allow(a).to receive(:post).and_return([])
      allow(a).to receive(:list_repo_files).and_return([])
      allow(a).to receive(:download_repo_file).and_return("content".b)
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_bytes_to_path)
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc", size: 10 })
      allow(x).to receive(:upload_batch).and_return([])
    end
  end
  let(:file_manager) do
    instance_double(HuggingFaceStorage::FileManager).tap do |fm|
      allow(fm).to receive(:exists?).and_return(false)
      allow(fm).to receive(:delete)
      allow(fm).to receive(:list).and_return([])
      allow(fm).to receive(:copy_from).and_return({ files_copied: 0 })
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:copy_pipeline) { HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger, config: config) }
  let(:same_bucket_copy) { HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager, logger: logger, config: config, copy_pipeline: copy_pipeline) }
  let(:source_iterator) { HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger) }
  let(:cross_repo_copy) { HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: copy_pipeline, bucket_id: bucket_id, source_iterator: source_iterator, logger: logger) }
  let(:service) do
    described_class.new(
      same_bucket_copy: same_bucket_copy, cross_repo_copy: cross_repo_copy, copy_pipeline: copy_pipeline,
      logger: logger, config: config
    )
  end
  let(:cross_repo_result) do
    { files_copied: 3, files_downloaded: 0, total: 3, skipped: 0, skipped_directories: 0,
      source: "model:org/repo" }
  end
  let(:same_bucket_result) do
    { from: "src", to: "dst", files_copied: 2, skipped: 0 }
  end

  describe "#copy_from_tree" do
    let(:tree) do
      [
        { "type" => "file", "path" => "Qwen/config.json", "size" => 660, "xetHash" => "hash1" },
        { "type" => "file", "path" => "Qwen/model.bin", "size" => 1000, "xetHash" => "hash2" },
        { "type" => "directory", "path" => "Qwen/figures" }
      ]
    end

    it "delegates to cross_repo_copy.copy_from_tree" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "filters by source_prefix" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree,
        source_prefix: "Qwen"
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "excludes files matching patterns" do
      result = service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree,
        exclude: "*.bin"
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "raises Error when no matching files found" do
      expect {
        service.copy_from_tree(
          source_type: "model", source_repo: "org/repo", tree: tree,
          source_prefix: "nonexistent"
        )
      }.to raise_error(HuggingFaceStorage::Error, /No matching files/)
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

    it "raises Error when tree file does not exist" do
      expect {
        service.copy_from_tree(
          source_type: "model", source_repo: "org/repo",
          tree: "/nonexistent/tree.json"
        )
      }.to raise_error(HuggingFaceStorage::Error, /Tree file not found/)
    end

    it "passes overwrite and cancel_token to cross_repo_copy" do
      token = instance_double(HuggingFaceStorage::CancelToken, raise_if_cancelled!: nil)

      service.copy_from_tree(
        source_type: "model", source_repo: "org/repo", tree: tree,
        overwrite: true, cancel_token: token
      )
      expect(token).to have_received(:raise_if_cancelled!).at_least(:once)
    end
  end

  describe "#copy_from_repo" do
    it "delegates to cross_repo_copy.copy_from_repo" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: nil, revision: "main", recursive: true)
        .and_return([
          { "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }
        ])

      result = service.copy_from_repo(
        source_type: "model", source_repo: "org/repo",
        destination_prefix: "models/cfg"
      )
      expect(result[:files_copied]).to eq(1)
    end

    it "supports source_path filter" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: "subdir", revision: "main", recursive: true)
        .and_return([
          { "type" => "file", "path" => "subdir/vocab.json", "size" => 200, "xetHash" => "h1" }
        ])

      result = service.copy_from_repo(
        source_type: "model", source_repo: "org/repo",
        source_path: "subdir", destination_prefix: "models/tok"
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

    it "raises Error when no files found" do
      allow(api).to receive(:list_repo_files).and_return([])

      expect {
        service.copy_from_repo(
          source_type: "model", source_repo: "org/empty-repo"
        )
      }.to raise_error(HuggingFaceStorage::Error, /No files found/)
    end
  end

  describe "#copy" do
    it "uses same_bucket_copy.copy when no source_type/source_repo given" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "src/f.txt", "size" => 10, "xetHash" => "h1" }])
      allow(file_manager).to receive(:exists?).and_return(false)

      result = service.copy("src", "dst")
      expect(result[:from]).to eq("src")
      expect(result[:files_copied]).to eq(1)
    end

    it "uses cross_repo_copy.copy_from_repo when source_type and source_repo given" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: nil, revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }])

      result = service.copy("", "models/cfg",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_copied]).to eq(1)
    end

    it "uses cross_repo_copy.copy_from_repo with custom revision" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: nil, revision: "v2", recursive: true)
        .and_return([{ "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }])

      result = service.copy("", "models/cfg",
        source_type: "model", source_repo: "org/repo", revision: "v2")
      expect(result[:files_copied]).to eq(1)
    end

    it "raises NotFoundError when same-bucket source directory is empty" do
      allow(file_manager).to receive(:list).and_return([])

      expect { service.copy("empty_dir", "dst") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#copy_folders" do
    it "returns zero when folders is empty" do
      result = service.copy_folders(folders: [])
      expect(result[:folders_copied]).to eq(0)
    end

    it "copies files from multiple folders" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo-a", path: "tokenizer", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "tokenizer/vocab.json", "size" => 200, "xetHash" => "h1" }])
      allow(api).to receive(:list_repo_files)
        .with("dataset", "org/data-b", path: "data", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "data/train.csv", "size" => 300, "xetHash" => "h2" }])

      result = service.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo-a", source_path: "tokenizer", destination: "models/a/" },
          { source_type: "dataset", source_repo: "org/data-b", source_path: "data", destination: "data/backup/" }
        ]
      )
      expect(result[:total]).to eq(2)
      expect(api).to have_received(:batch).at_least(:once)
    end

    it "raises Error when no files found after filtering" do
      allow(api).to receive(:list_repo_files)
        .and_return([{ "type" => "directory", "path" => "src/subdir" }])

      expect {
        service.copy_folders(
          folders: [
            { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dst" }
          ]
        )
      }.to raise_error(HuggingFaceStorage::Error, /No files found/)
    end

    it "passes exclude filter to cross_repo_copy" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "tokenizer/vocab.json", "size" => 200, "xetHash" => "h1" },
          { "type" => "file", "path" => "tokenizer/debug.log", "size" => 50, "xetHash" => "h2" }
        ])

      result = service.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "tokenizer",
            destination: "models/tok/", exclude: "*.log" }
        ]
      )
      expect(result[:total]).to eq(1)
    end
  end
end
