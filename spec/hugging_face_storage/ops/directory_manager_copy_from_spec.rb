# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryManager do
  include_context "with null logger"
  include_context "with directory manager services"

  # ── Copy from tree ──

  describe "#copy_from_tree" do
    let(:tree) do
      [
        { "type" => "file", "path" => "Qwen/config.json", "size" => 660, "xetHash" => "hash1" },
        { "type" => "file", "path" => "Qwen/model.bin", "size" => 1000, "xetHash" => "hash2" },
        { "type" => "directory", "path" => "Qwen/figures" },
        { "type" => "file", "path" => "deepseek/config.json", "size" => 500, "xetHash" => "hash3" }
      ]
    end

    it "copies all files from tree" do
      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree
      )
      expect(result[:files_copied]).to eq(3)
      expect(file_manager).to have_received(:copy_from)
    end

    it "filters by source_prefix" do
      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree,
        source_prefix: "Qwen"
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "remaps destination with destination_prefix" do
      dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree,
        source_prefix: "Qwen",
        destination_prefix: "models/Qwen-copy"
      )

      expect(file_manager).to have_received(:copy_from) do |args|
        files = args[:files]
        expect(files[0][:destination]).to start_with("models/Qwen-copy/")
      end
    end

    it "excludes files matching patterns" do
      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree,
        exclude: "*.bin"
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "raises Error when no matching files found" do
      expect {
        dm.copy_from_tree(
          source_type: "bucket",
          source_repo: "user/source",
          tree: tree,
          source_prefix: "nonexistent"
        )
      }.to raise_error(HuggingFaceStorage::Error, /No matching files/)
    end

    it "loads tree from JSON file" do
      Dir.mktmpdir do |dir|
        json_path = File.join(dir, "tree.json")
        File.write(json_path, JSON.generate(tree))

        result = dm.copy_from_tree(
          source_type: "bucket",
          source_repo: "user/source",
          tree: json_path
        )
        expect(result[:files_copied]).to eq(3)
      end
    end

    it "raises Error when tree file does not exist" do
      expect {
        dm.copy_from_tree(
          source_type: "bucket",
          source_repo: "user/source",
          tree: "/nonexistent/tree.json"
        )
      }.to raise_error(HuggingFaceStorage::Error, /Tree file not found/)
    end

    it "skips existing files when overwrite is false and destination is set" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([
          { "type" => "file", "path" => "dest/config.json", "size" => 100, "xetHash" => "h1" },
          { "type" => "file", "path" => "dest/model.bin", "size" => 200, "xetHash" => "h2" }
        ])

      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree,
        source_prefix: "Qwen",
        destination_prefix: "dest",
        overwrite: false
      )
      expect(result[:files_copied]).to eq(0)
      expect(result[:skipped]).to eq(2)
    end

    it "overwrites when overwrite is true" do
      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: tree,
        overwrite: true
      )
      expect(result[:files_copied]).to eq(3)
    end

    it "returns early when all files already exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([
          { "type" => "file", "path" => "backup/a.txt", "size" => 10, "xetHash" => "h1" },
          { "type" => "file", "path" => "backup/b.txt", "size" => 20, "xetHash" => "h2" }
        ])

      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: [
          { "type" => "file", "path" => "Qwen/a.txt", "size" => 10, "xetHash" => "h1" },
          { "type" => "file", "path" => "Qwen/b.txt", "size" => 20, "xetHash" => "h2" }
        ],
        source_prefix: "Qwen",
        destination_prefix: "backup",
        overwrite: false
      )
      expect(result[:files_copied]).to eq(0)
      expect(result[:skipped]).to eq(2)
    end

    it "uses destination_prefix without source_prefix (elsif dest branch)" do
      result = dm.copy_from_tree(
        source_type: "bucket",
        source_repo: "user/source",
        tree: [
          { "type" => "file", "path" => "Qwen/a.txt", "size" => 10, "xetHash" => "h1" },
          { "type" => "file", "path" => "Qwen/b.txt", "size" => 20, "xetHash" => "h2" }
        ],
        destination_prefix: "target"
      )
      expect(result[:files_copied]).to eq(2)
      expect(file_manager).to have_received(:copy_from) do |args|
        expect(args[:files][0][:destination]).to eq("target/Qwen/a.txt")
      end
    end
  end

  # ── Copy from repo ──

  describe "#copy_from_repo" do
    let(:model_tree) do
      [
        { "type" => "file", "path" => "config.json", "size" => 660, "xetHash" => "hash_config" },
        { "type" => "file", "path" => "model.safetensors", "size" => 3_000_000_000, "xetHash" => "hash_model" },
        { "type" => "file", "path" => "tokenizer.json", "size" => 7_000_000, "xetHash" => "hash_tokenizer" },
        { "type" => "file", "path" => "README.md", "size" => 500 },
        { "type" => "directory", "path" => "figures" }
      ]
    end

    it "copies all xet-backed files server-side and downloads non-xet files" do
      allow(api).to receive(:list_repo_files)
        .with("model", "moonshotai/MoonViT-SO-400M", path: nil, revision: "main", recursive: true)
        .and_return(model_tree)

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "moonshotai/MoonViT-SO-400M",
        destination_prefix: "models/moonvit"
      )

      expect(result[:files_copied]).to eq(3)
      expect(result[:files_downloaded]).to eq(1)
      expect(result[:source]).to eq("model:moonshotai/MoonViT-SO-400M")

      expect(api).to have_received(:batch).with(
        bucket_id,
        array_including(
          hash_including(path: "models/moonvit/config.json"),
          hash_including(path: "models/moonvit/model.safetensors"),
          hash_including(path: "models/moonvit/tokenizer.json")
        ),
        anything
      ).at_least(:once)

      expect(api).to have_received(:download_repo_file)
        .with("model", "moonshotai/MoonViT-SO-400M", "README.md", hash_including(revision: "main"))
      expect(uploader).to have_received(:upload_batch)
        .with(bucket_id, array_including(hash_including(remote_path: "models/moonvit/README.md")), hash_including(cancel_token: nil))
    end

    it "uses nil revision for bucket source" do
      allow(api).to receive(:list_repo_files)
        .with("bucket", "user/src-bucket", path: nil, revision: nil, recursive: true)
        .and_return([
          { "type" => "file", "path" => "data.bin", "size" => 100, "xetHash" => "h1" }
        ])

      dm.copy_from_repo(
        source_type: "bucket",
        source_repo: "user/src-bucket",
        destination_prefix: "backup"
      )

      expect(api).to have_received(:list_repo_files)
        .with("bucket", "user/src-bucket", path: nil, revision: nil, recursive: true)
    end

    it "copies only files under source_path" do
      allow(api).to receive(:list_repo_files)
        .with("model", "Qwen/Qwen2.5-0.5B-Instruct", path: "tokenizer_files", revision: "main", recursive: true)
        .and_return([
          { "type" => "file", "path" => "tokenizer_files/vocab.json", "size" => 100, "xetHash" => "h1" }
        ])

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
        source_path: "tokenizer_files",
        destination_prefix: "models/qwen/tokenizer"
      )

      expect(result[:files_copied]).to eq(1)
      expect(api).to have_received(:batch).with(
        bucket_id,
        array_including(hash_including(path: "models/qwen/tokenizer/vocab.json")),
        anything
      ).at_least(:once)
    end

    it "excludes files matching patterns" do
      allow(api).to receive(:list_repo_files)
        .and_return(model_tree)

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "moonshotai/MoonViT-SO-400M",
        destination_prefix: "models/moonvit",
        exclude: ["*.safetensors"]
      )

      expect(result[:files_copied]).to eq(2)
      expect(result[:files_downloaded]).to eq(1)
    end

    it "raises Error for unmigrated LFS files" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "model.bin", "size" => 5_000_000_000,
            "lfs" => { "oid" => "abc", "size" => 5_000_000_000, "pointerSize" => 134 } }
        ])

      expect {
        dm.copy_from_repo(
          source_type: "model",
          source_repo: "user/old-model",
          destination_prefix: "models/old"
        )
      }.to raise_error(HuggingFaceStorage::Error, /LFS file.*not been migrated to xet.*model\.bin/)
    end

    it "raises Error when no files found" do
      allow(api).to receive(:list_repo_files).and_return([])

      expect {
        dm.copy_from_repo(
          source_type: "model",
          source_repo: "user/empty-repo"
        )
      }.to raise_error(HuggingFaceStorage::Error, /No files found/)
    end

    it "copies to root when no destination_prefix" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }
        ])

      dm.copy_from_repo(
        source_type: "model",
        source_repo: "user/model"
      )

      expect(api).to have_received(:batch).with(
        bucket_id,
        array_including(hash_including(path: "config.json")),
        anything
      ).at_least(:once)
    end

    it "supports custom revision" do
      allow(api).to receive(:list_repo_files)
        .with("model", "user/model", path: nil, revision: "v2.0", recursive: true)
        .and_return([
          { "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }
        ])

      dm.copy_from_repo(
        source_type: "model",
        source_repo: "user/model",
        revision: "v2.0",
        destination_prefix: "models/v2"
      )

      expect(api).to have_received(:list_repo_files)
        .with("model", "user/model", path: nil, revision: "v2.0", recursive: true)
    end

    it "handles non-JSON error message in NotFoundError rescue" do
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError, "plain error message")

      expect {
        dm.copy_from_repo(
          source_type: "model",
          source_repo: "org/repo"
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError) { |e|
        expect(e.message).to include("plain error message")
      }
    end

    it "counts skipped files when destination already has existing files" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([
          { "type" => "file", "path" => "dest/a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "org/repo",
        destination_prefix: "dest",
        overwrite: false
      )
      expect(result[:files_copied]).to eq(0)
      expect(result[:skipped]).to eq(1)
    end

    it "returns early when all source files already exist at destination" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([{ "type" => "file", "path" => "dest/a.txt", "size" => 10, "xetHash" => "h1" }])

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "org/repo",
        destination_prefix: "dest"
      )
      expect(result[:files_copied]).to eq(0)
      expect(result[:skipped]).to eq(1)
    end

    it "initializes skipped counts when overwrite is true" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "org/repo",
        destination_prefix: "dest",
        overwrite: true
      )
      expect(result[:files_copied]).to eq(1)
      expect(result[:skipped]).to eq(0)
    end

    it "downloads non-xet files via RepoFileCopier" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "readme.md", "size" => 50 }
        ])

      result = dm.copy_from_repo(
        source_type: "model",
        source_repo: "org/repo",
        destination_prefix: "dest"
      )
      expect(result[:files_downloaded]).to eq(1)
      expect(api).to have_received(:download_repo_file)
        .with("model", "org/repo", "readme.md", hash_including(revision: "main"))
      expect(uploader).to have_received(:upload_batch)
        .with(bucket_id, array_including(hash_including(remote_path: "dest/readme.md")), hash_including(cancel_token: nil))
    end

    # rubocop:disable RSpec/ExampleLength
    it "flushes large file batch when threshold is reached" do
      custom_config = HuggingFaceStorage::Configuration.new(copy_batch_size: 5)
      cp = HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger,
config: custom_config)
      sbc = HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager,
logger: logger, config: custom_config, copy_pipeline: cp)
      si = HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger)
      crc = HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: cp,
bucket_id: bucket_id, source_iterator: si, logger: logger)
      dcs = HuggingFaceStorage::DirectoryCopyService.new(same_bucket_copy: sbc, cross_repo_copy: crc, copy_pipeline: cp, logger: logger,
config: custom_config)
      custom_dm = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager,
        bucket_id: bucket_id, logger: logger, config: custom_config,
        crud_service: crud_service, transfer_service: transfer_service, copy_service: dcs
      )
      large_files = (1..10).map do |i|
        { "type" => "file", "path" => "big#{i}.bin", "size" => 200_000 }
      end
      allow(api).to receive(:list_repo_files).and_return(large_files)
      allow(uploader).to receive(:stream_download_and_upload) do |_bid, path, **_opts, &block|
        block.call(proc { |chunk| })
        { remote_path: "dest/#{File.basename(path)}", xet_hash: "sh_#{path}" }
      end
      allow(api).to receive(:download_repo_file_streaming)
      batch_calls = []
      allow(api).to receive(:batch) do |_bid, ops, **_opts|
        batch_calls << ops.size
        HuggingFaceStorage::BatchResult.new
      end

      result = custom_dm.copy_from_repo(
        source_type: "model",
        source_repo: "org/repo",
        destination_prefix: "dest"
      )
      expect(result[:files_downloaded]).to eq(10)
      expect(batch_calls).to include(5)
    end
    # rubocop:enable RSpec/ExampleLength
  end
end
