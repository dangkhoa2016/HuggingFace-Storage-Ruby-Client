# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryManager do
  include_context "with null logger"
  include_context "with directory manager services"

  # ── Copy (same bucket and cross-repo) ──

  describe "#copy" do
    it "copies within same bucket" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "src/f.txt", "size" => 10, "xetHash" => "h1" }])
      allow(file_manager).to receive(:exists?).and_return(false)

      result = dm.copy("src", "dst")
      expect(result[:from]).to eq("src")
      expect(result[:files_copied]).to eq(1)
    end

    it "copies from external repo via cross-repo path" do
      allow(api).to receive(:list_repo_files)
        .and_return([{ "type" => "file", "path" => "config.json", "size" => 100, "xetHash" => "h1" }])

      result = dm.copy("", "models/cfg",
        source_type: "model", source_repo: "org/model")
      expect(result[:files_copied]).to eq(1)
    end

    it "raises NotFoundError when source directory is empty" do
      allow(file_manager).to receive(:list).and_return([])

      expect { dm.copy("empty_dir", "dst") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  # ── Copy folders ──

  describe "#copy_folders" do
    it "returns zero when folders is empty" do
      result = dm.copy_folders(folders: [])
      expect(result[:folders_copied]).to eq(0)
    end

    it "copies files from multiple folders" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo-a", path: "tokenizer", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "tokenizer/vocab.json", "size" => 200, "xetHash" => "h1" }])
      allow(api).to receive(:list_repo_files)
        .with("dataset", "org/data-b", path: "data", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "data/train.csv", "size" => 300, "xetHash" => "h2" }])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo-a", source_path: "tokenizer", destination: "models/a/" },
          { source_type: "dataset", source_repo: "org/data-b", source_path: "data", destination: "data/backup/" }
        ]
      )
      expect(result[:total]).to eq(2)
      expect(api).to have_received(:batch).at_least(:once)
    end

    it "handles trailing-slash destination by appending basename" do
      allow(api).to receive(:list_repo_files)
        .and_return([{ "type" => "file", "path" => "src/main.rs", "size" => 100, "xetHash" => "h1" }])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "backup/" }
        ]
      )
      expect(result[:total]).to eq(1)
    end

    it "handles NotFoundError with non-JSON message" do
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError, "not JSON error")

      expect {
        dm.copy_folders(
          folders: [
            { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dst" }
          ]
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError) { |e|
        expect(e.message).to include("not JSON error")
      }
    end

    it "handles NotFoundError with debug_mode preserving backtrace" do
      debug_config = HuggingFaceStorage::Configuration.new(debug_mode: true)
      cp = HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger,
config: debug_config)
      sbc = HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager,
logger: logger, config: debug_config, copy_pipeline: cp)
      si = HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger, debug_mode: true)
      crc = HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: cp,
bucket_id: bucket_id, source_iterator: si, logger: logger)
      dcs = HuggingFaceStorage::DirectoryCopyService.new(same_bucket_copy: sbc, cross_repo_copy: crc, copy_pipeline: cp, logger: logger,
config: debug_config)
      dm_debug = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager,
        bucket_id: bucket_id, logger: logger, crud_service: crud_service, transfer_service: transfer_service, copy_service: dcs
      )
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError,
          'Resource not found: {"error":"path does not exist"}')

      expect {
        dm_debug.copy_folders(
          folders: [
            { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dst" }
          ]
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError) { |e|
        expect(e.backtrace).not_to be_empty
        expect(e.cause).to be_a(HuggingFaceStorage::NotFoundError)
      }
    end

    it "excludes files matching patterns" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "tokenizer/vocab.json", "size" => 200, "xetHash" => "h1" },
          { "type" => "file", "path" => "tokenizer/debug.log", "size" => 50, "xetHash" => "h2" }
        ])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "tokenizer",
            destination: "models/tok/", exclude: "*.log" }
        ]
      )
      expect(result[:total]).to eq(1)
    end

    it "raises Error when no files found after filtering" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "directory", "path" => "src/subdir" }
        ])

      expect {
        dm.copy_folders(
          folders: [
            { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dst" }
          ]
        )
      }.to raise_error(HuggingFaceStorage::Error, /No files found/)
    end

    it "returns early when all files in the folder already exist at destination" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "src/a.txt", "size" => 10, "xetHash" => "h1" }
        ])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([
          { "type" => "file", "path" => "dest/a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dest" }
        ]
      )
      expect(result[:skipped]).to eq(1)
      expect(result[:total]).to eq(0)
    end

    it "initializes skipped counts to zero when overwrite is true" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "src/a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dest" }
        ],
        overwrite: true
      )
      expect(result[:skipped]).to eq(0)
      expect(result[:skipped_directories]).to eq(0)
    end

    it "downloads non-xet small files with progress callback" do
      on_progress = double("progress")
      allow(on_progress).to receive(:call)

      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "src/readme.md", "size" => 50 }
        ])

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dest" }
        ],
        on_progress: on_progress
      )
      expect(result[:files_downloaded]).to eq(1)
      expect(api).to have_received(:download_repo_file)
      expect(uploader).to have_received(:upload_batch)
    end

    it "downloads large non-xet files via streaming" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "src/big.bin", "size" => 200_000 }
        ])
      allow(uploader).to receive(:stream_download_and_upload) do |_bid, _path, **_opts, &block|
        block.call(proc { |chunk| })
        { remote_path: "dest/big.bin", xet_hash: "streamed_hash" }
      end
      allow(api).to receive(:download_repo_file_streaming)

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dest" }
        ]
      )
      expect(result[:files_downloaded]).to eq(1)
      expect(uploader).to have_received(:stream_download_and_upload)
    end

    it "flushes large file batch when 10+ large pending downloads" do
      large_files = (1..10).map do |i|
        { "type" => "file", "path" => "src/big#{i}.bin", "size" => 200_000 }
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

      result = dm.copy_folders(
        folders: [
          { source_type: "model", source_repo: "org/repo", source_path: "src", destination: "dest" }
        ]
      )
      expect(result[:files_downloaded]).to eq(10)
      expect(batch_calls).to include(10)
    end
  end

  # ── Debug mode error handling in copy_from_repo ──

  describe "debug mode" do
    it "hides backtrace when debug_mode=false (default)" do
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError,
          'Resource not found: {"error":"path does not exist"}')

      expect {
        dm.copy_from_repo(
          source_type: "model",
          source_repo: "org/missing-repo"
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
        expect(e.backtrace).to eq([])
        expect(e.cause).to be_a(HuggingFaceStorage::NotFoundError)
      end
    end

    it "preserves backtrace when debug_mode=true" do
      dm_cfg = HuggingFaceStorage::Configuration.new(debug_mode: true)
      dm_cp = HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger,
config: dm_cfg)
      dm_sbc = HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager,
logger: logger, config: dm_cfg, copy_pipeline: dm_cp)
      dm_si = HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger, debug_mode: true)
      dm_crc = HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: dm_cp,
bucket_id: bucket_id, source_iterator: dm_si, logger: logger)
      dm_cs = HuggingFaceStorage::DirectoryCopyService.new(same_bucket_copy: dm_sbc, cross_repo_copy: dm_crc, copy_pipeline: dm_cp,
logger: logger, config: dm_cfg)
      dm_debug = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager,
        bucket_id: bucket_id, logger: logger,
        crud_service: crud_service, transfer_service: transfer_service, copy_service: dm_cs
      )
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError,
          'Resource not found: {"error":"path does not exist"}')

      expect {
        dm_debug.copy_from_repo(
          source_type: "model",
          source_repo: "org/missing-repo"
        )
      }.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
        expect(e.backtrace).not_to be_empty
        expect(e.cause).to be_a(HuggingFaceStorage::NotFoundError)
      end
    end
  end

  # ── Same-bucket copy (private) ──

  describe "same-bucket copy (private)" do
    it "copies multiple source directories into single destination" do
      allow(file_manager).to receive(:list)
        .with(prefix: "d1", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "d1/f.txt", size: 10)])
      allow(file_manager).to receive(:list)
        .with(prefix: "d2", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "d2/g.txt", size: 20)])
      allow(api).to receive(:post)
        .and_return(
          [],  # batch_exists? for d1 — no existing
          [{ "path" => "d1/f.txt", "size" => 10, "xetHash" => "h1" }],  # fetch_file_info for d1
          [],  # batch_exists? for d2 — no existing
          [{ "path" => "d2/g.txt", "size" => 20, "xetHash" => "h2" }]   # fetch_file_info for d2
        )

      result = dm.copy(["d1", "d2"], "backup")
      expect(result[:total_files_copied]).to eq(2)
    end

    it "skips existing files when overwrite is false" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post).with(
        "/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info",
        hash_including(body: hash_including(paths: ["dst/f.txt"]))
      ).and_return([{ "path" => "dst/f.txt", "type" => "file", "size" => 10 }])

      result = dm.copy("src", "dst", overwrite: false)
      expect(result[:skipped]).to eq(1)
      expect(result[:files_copied]).to eq(0)
    end

    it "overwrites existing files when overwrite is true" do
      allow(file_manager).to receive(:list)
        .with(prefix: "src", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "src/f.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "src/f.txt", "size" => 10, "xetHash" => "h1" }])
      allow(file_manager).to receive(:exists?).and_return(true)

      result = dm.copy("src", "dst", overwrite: true)
      expect(result[:files_copied]).to eq(1)
    end
  end

  # ── Cross-repo copy (private) ──

  describe "cross-repo copy (private)" do
    it "copies from external repo with multiple sources" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: "dir1", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "dir1/a.txt", "size" => 10, "xetHash" => "h1" }])
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: "dir2", revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "dir2/b.txt", "size" => 20, "xetHash" => "h2" }])

      result = dm.copy(["dir1", "dir2"], "backup",
        source_type: "model", source_repo: "org/repo")
      expect(result[:total]).to eq(2)
    end

    it "handles empty source path" do
      allow(api).to receive(:list_repo_files)
        .with("model", "org/repo", path: nil, revision: "main", recursive: true)
        .and_return([{ "type" => "file", "path" => "root.txt", "size" => 5, "xetHash" => "h1" }])

      result = dm.copy("", "dst",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_copied]).to eq(1)
    end

    it "excludes files matching patterns" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" },
          { "type" => "file", "path" => "a.log", "size" => 5, "xetHash" => "h2" }
        ])

      result = dm.copy("", "dst",
        source_type: "model", source_repo: "org/repo", exclude: "*.log")
      expect(result[:files_copied]).to eq(1)
    end

    it "handles NotFoundError with non-JSON message" do
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError, "plain text error")

      expect {
        dm.copy("src", "dst", source_type: "model", source_repo: "org/repo")
      }.to raise_error(HuggingFaceStorage::NotFoundError) { |e|
        expect(e.message).to include("plain text error")
      }
    end

    it "handles NotFoundError with debug_mode preserving backtrace" do
      debug_config = HuggingFaceStorage::Configuration.new(debug_mode: true)
      cp = HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger,
config: debug_config)
      sbc = HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager,
logger: logger, config: debug_config, copy_pipeline: cp)
      si = HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger, debug_mode: true)
      crc = HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: cp,
bucket_id: bucket_id, source_iterator: si, logger: logger)
      dcs = HuggingFaceStorage::DirectoryCopyService.new(same_bucket_copy: sbc, cross_repo_copy: crc, copy_pipeline: cp, logger: logger,
config: debug_config)
      dm_debug = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager,
        bucket_id: bucket_id, logger: logger, crud_service: crud_service, transfer_service: transfer_service, copy_service: dcs
      )
      allow(api).to receive(:list_repo_files)
        .and_raise(HuggingFaceStorage::NotFoundError,
          'Resource not found: {"error":"not found"}')

      expect {
        dm_debug.copy("src", "dst", source_type: "model", source_repo: "org/repo")
      }.to raise_error(HuggingFaceStorage::NotFoundError) { |e|
        expect(e.backtrace).not_to be_empty
        expect(e.cause).to be_a(HuggingFaceStorage::NotFoundError)
      }
    end

    it "raises Error when no files found after filtering" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      expect {
        dm.copy("src", "dst",
          source_type: "model", source_repo: "org/repo",
          exclude: "*.txt")
      }.to raise_error(HuggingFaceStorage::Error, /No files found/)
    end

    it "initializes skipped counts to zero when overwrite is true" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy("src", "dst",
        source_type: "model", source_repo: "org/repo", overwrite: true)
      expect(result[:files_copied]).to eq(1)
      expect(result[:skipped]).to eq(0)
      expect(result[:skipped_directories]).to eq(0)
    end

    it "returns early when all files already exist at destination" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "h1" }
        ])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: kind_of(Array) }))
        .and_return([
          { "type" => "file", "path" => "dst/a.txt", "size" => 10, "xetHash" => "h1" }
        ])

      result = dm.copy("src", "dst",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_copied]).to eq(0)
      expect(result[:skipped]).to eq(1)
    end

    it "downloads non-xet small files via RepoFileCopier" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "readme.md", "size" => 50 }
        ])

      result = dm.copy("", "dst",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_downloaded]).to eq(1)
      expect(api).to have_received(:download_repo_file)
    end

    it "downloads large non-xet files via streaming" do
      allow(api).to receive(:list_repo_files)
        .and_return([
          { "type" => "file", "path" => "big.bin", "size" => 200_000 }
        ])
      allow(uploader).to receive(:stream_download_and_upload) do |_bid, _path, **_opts, &block|
        block.call(proc { |chunk| })
        { remote_path: "dst/big.bin", xet_hash: "streamed_hash" }
      end
      allow(api).to receive(:download_repo_file_streaming)

      result = dm.copy("", "dst",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_downloaded]).to eq(1)
      expect(uploader).to have_received(:stream_download_and_upload)
    end

    it "flushes large file batch when 10+ large pending downloads" do
      large_files = (1..10).map do |i|
        { "type" => "file", "path" => "big#{i}.bin", "size" => 200_000 }
      end
      allow(api).to receive(:list_repo_files).and_return(large_files)
      allow(uploader).to receive(:stream_download_and_upload) do |_bid, path, **_opts, &block|
        block.call(proc { |chunk| })
        { remote_path: "dst/#{File.basename(path)}", xet_hash: "sh_#{path}" }
      end
      allow(api).to receive(:download_repo_file_streaming)
      batch_calls = []
      allow(api).to receive(:batch) do |_bid, ops, **_opts|
        batch_calls << ops.size
        HuggingFaceStorage::BatchResult.new
      end

      result = dm.copy("", "dst",
        source_type: "model", source_repo: "org/repo")
      expect(result[:files_downloaded]).to eq(10)
      expect(batch_calls).to include(10)
    end
  end
end
