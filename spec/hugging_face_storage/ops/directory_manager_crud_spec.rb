# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryManager do
  include_context "with null logger"
  include_context "with directory manager services"

  # ── Create ──

  describe "#create" do
    it "creates directory by uploading empty placeholder" do
      result = dm.create("new_folder")
      expect(result).to be true
      expect(uploader).to have_received(:upload_bytes_to_path).with(bucket_id, anything, "new_folder/",
cancel_token: nil)
    end

    it "returns true immediately if directory already exists" do
      allow(api).to receive(:head)
        .with("/api/buckets/#{bucket_id}/tree/existing")
        .and_return(double("response"))

      result = dm.create("existing")
      expect(result).to be true
      expect(uploader).not_to have_received(:upload_bytes_to_path)
    end

    it "normalizes trailing slashes" do
      dm.create("folder/")
      expect(uploader).to have_received(:upload_bytes_to_path).with(bucket_id, anything, "folder/", cancel_token: nil)
    end
  end

  # ── Exists? ──

  describe "#exists?" do
    it "returns true when directory has entries" do
      allow(api).to receive(:head)
        .with("/api/buckets/#{bucket_id}/tree/models")
        .and_return(double("response"))

      expect(dm.exists?("models")).to be true
    end

    it "returns false when directory is empty and no placeholder" do
      expect(dm.exists?("empty_dir")).to be false
    end

    it "returns true when only placeholder exists" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", body: { paths: ["my_dir"] })
        .and_return([{ "path" => "my_dir", "type" => "directory", "size" => 0 }])

      expect(dm.exists?("my_dir")).to be true
    end

    it "returns false when both head and paths-info raise errors" do
      allow(api).to receive(:post).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      expect(dm.exists?("missing")).to be false
    end
  end

  # ── List ──

  describe "#list" do
    it "returns DirInfo objects for directories only" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree", params: { recursive: "false" })
        .and_return([
          { "type" => "directory", "path" => "models", "uploadedAt" => "2026-01-01" },
          { "type" => "file", "path" => "readme.txt", "size" => 100 },
          { "type" => "directory", "path" => "data", "uploadedAt" => "2026-01-02" }
        ])

      dirs = dm.list
      expect(dirs.size).to eq(2)
      expect(dirs[0]).to be_a(HuggingFaceStorage::DirInfo)
      expect(dirs[0].path).to eq("models")
      expect(dirs[1].path).to eq("data")
    end

    it "supports prefix filter" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree/deepseek-ai", params: { recursive: "false" })
        .and_return([{ "type" => "directory", "path" => "deepseek-ai/R1" }])

      dirs = dm.list(prefix: "deepseek-ai")
      expect(dirs.size).to eq(1)
    end
  end

  # ── List Files ──

  describe "#list_files" do
    it "delegates to file_manager.list" do
      allow(file_manager).to receive(:list)
        .with(prefix: "Qwen", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "Qwen/config.json", size: 660)])

      files = dm.list_files("Qwen", recursive: true)
      expect(files.size).to eq(1)
      expect(files[0].path).to eq("Qwen/config.json")
    end
  end

  # ── Metadata ──

  describe "#metadata" do
    it "returns DirInfo with file count and total size" do
      allow(file_manager).to receive(:list)
        .with(prefix: "models", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "models/a.txt", size: 100),
          HuggingFaceStorage::FileInfo.new(path: "models/b.txt", size: 200)
        ])

      info = dm.metadata("models")
      expect(info).to be_a(HuggingFaceStorage::DirInfo)
      expect(info.path).to eq("models")
      expect(info.file_count).to eq(2)
      expect(info.total_size).to eq(300)
    end

    it "handles concurrent metadata calls without race" do
      allow(file_manager).to receive(:list)
        .with(prefix: "models", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "models/a.txt", size: 100)
        ])

      results = []
      mutex = Mutex.new
      threads = Array.new(10) do
        Thread.new do
          info = dm.metadata("models")
          mutex.synchronize { results << info.file_count }
        end
      end
      threads.each(&:join)
      expect(results).to all(eq(1))
    end
  end

  # ── Delete ──

  describe "#delete" do
    it "deletes all files recursively" do
      allow(file_manager).to receive(:list)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "dir/a.txt", size: 10),
          HuggingFaceStorage::FileInfo.new(path: "dir/b.txt", size: 20)
        ])

      result = dm.delete("dir", recursive: true)
      expect(result).to be true

      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "dir/a.txt" },
        { type: "deleteFile", path: "dir/b.txt" },
        { type: "deleteFile", path: "dir/" }
      ], hash_including(cancel_token: nil))
    end

    it "raises Error for non-empty directory without recursive flag" do
      allow(file_manager).to receive(:list)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "dir/file.txt", size: 10)])

      expect { dm.delete("dir", recursive: false) }
        .to raise_error(HuggingFaceStorage::Error, /not empty/)
    end

    it "deletes placeholder for empty directory" do
      allow(file_manager).to receive(:list).and_return([])

      result = dm.delete("empty_dir")
      expect(result).to be true
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "empty_dir/" }
      ], hash_including(cancel_token: nil))
    end

    it "deletes multiple directories when given an array" do
      allow(file_manager).to receive(:list)
        .with(prefix: "d1", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "d1/f.txt", size: 10)])
      allow(file_manager).to receive(:list)
        .with(prefix: "d2", recursive: true)
        .and_return([])

      result = dm.delete(["d1", "d2"], recursive: true)
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "d1/f.txt" },
        { type: "deleteFile", path: "d1/" },
        { type: "deleteFile", path: "d2/" }
      ], hash_including(cancel_token: nil))
    end

    it "splits into multiple batch calls when operations exceed DELETE_BATCH_SIZE" do
      files = (1..25).map { |i| HuggingFaceStorage::FileInfo.new(path: "dir/f#{i}.txt", size: i) }
      allow(file_manager).to receive(:list)
        .with(prefix: "dir", recursive: true)
        .and_return(files)

      batch_calls = []
      allow(api).to receive(:batch) do |_, ops, **|
        batch_calls << ops
        HuggingFaceStorage::BatchResult.new
      end

      result = dm.delete("dir", recursive: true)
      expect(result).to be true
      expect(batch_calls.size).to eq(2)
      expect(batch_calls[0].size).to eq(20)
      expect(batch_calls[1].size).to eq(6)
    end
  end

  # ── Download ──

  describe "#download" do
    it "downloads all files in directory" do
      allow(file_manager).to receive(:list)
        .with(prefix: "models/Qwen", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "models/Qwen/config.json", size: 660),
          HuggingFaceStorage::FileInfo.new(path: "models/Qwen/model.bin", size: 1000)
        ])

      Dir.mktmpdir do |dir|
        result = dm.download("models/Qwen", dir)
        expect(result[:files_downloaded]).to eq(2)
        expect(downloader).to have_received(:download_file).twice
      end
    end

    it "raises NotFoundError for empty directory" do
      allow(file_manager).to receive(:list).and_return([])

      expect { dm.download("empty", "/tmp/out") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /No files found/)
    end
  end

  # ── Upload ──

  describe "#upload" do
    it "uploads directory with small files as batch" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "small file a")
        File.write(File.join(dir, "b.txt"), "small file b")

        allow(uploader).to receive(:upload_batch)

        result = dm.upload(dir, "remote/dir")
        expect(result[:files_uploaded]).to eq(2)
        expect(uploader).to have_received(:upload_batch).once
      end
    end

    it "uploads large files individually", :slow do
      Dir.mktmpdir do |dir|
        large_content = "x" * (100 * 1024 * 1024 + 1)
        File.write(File.join(dir, "large.bin"), large_content)

        result = dm.upload(dir, "remote/dir")
        expect(result[:files_uploaded]).to eq(1)
        expect(uploader).to have_received(:upload_file_to_path).once
      end
    end

    it "mixes batch and individual uploads", :slow do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "small.txt"), "small")
        large_content = "x" * (100 * 1024 * 1024 + 1)
        File.write(File.join(dir, "large.bin"), large_content)

        allow(uploader).to receive(:upload_batch)

        result = dm.upload(dir, "remote/dir")
        expect(result[:files_uploaded]).to eq(2)
        expect(uploader).to have_received(:upload_batch).once
        expect(uploader).to have_received(:upload_file_to_path).once
      end
    end

    it "raises Error when directory does not exist" do
      expect { dm.upload("/nonexistent", "remote") }
        .to raise_error(HuggingFaceStorage::Error, /Local directory not found/)
    end

    it "raises Error when directory is empty" do
      Dir.mktmpdir do |dir|
        expect { dm.upload(dir, "remote") }
          .to raise_error(HuggingFaceStorage::Error, /No files found/)
      end
    end

    it "excludes files matching patterns" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "keep.txt"), "keep")
        File.write(File.join(dir, "skip.log"), "skip")

        allow(uploader).to receive(:upload_batch)

        result = dm.upload(dir, "remote", exclude: "*.log")
        expect(result[:files_uploaded]).to eq(1)
      end
    end
  end

  # ── Move ──

  describe "#move" do
    it "moves all files in directory with one batch paths-info call" do
      files = 12.times.map { |i| HuggingFaceStorage::FileInfo.new(path: "old_dir/file#{i}.txt", size: 10 + i) }

      allow(file_manager).to receive(:list)
        .with(prefix: "old_dir", recursive: true)
        .and_return(files)

      expect(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", hash_including(body: hash_including(paths: files.map(&:path))))
        .once
        .and_return(files.each_with_index.map { |file, i|
                      { "path" => file.path, "size" => file.size, "xetHash" => "h#{i}" }
                    })

      result = dm.move("old_dir", "new_dir")
      expect(result[:from]).to eq("old_dir")
      expect(result[:to]).to eq("new_dir")
      expect(result[:files_moved]).to eq(12)
    end

    it "raises NotFoundError when directory is empty" do
      allow(file_manager).to receive(:list).and_return([])

      expect { dm.move("empty", "new") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  # ── Rename ──

  describe "#rename" do
    it "delegates to move" do
      allow(file_manager).to receive(:list)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "old/a.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "old/a.txt", "size" => 10, "xetHash" => "h1" }])

      result = dm.rename("old", "new")
      expect(result[:from]).to eq("old")
      expect(result[:to]).to eq("new")
    end
  end

  # ── Snapshot download ──

  describe "#snapshot_download" do
    it "delegates to Snapshot#download" do
      allow(file_manager).to receive(:list).and_return([
        HuggingFaceStorage::FileInfo.new(path: "data/a.txt", size: 5, xet_hash: "h1", mtime: "2026-01-01")
      ])
      allow(downloader).to receive(:download_file) do |_bid, _rp, local_path, **|
        FileUtils.mkdir_p(File.dirname(local_path))
        File.write(local_path, "content")
      end

      Dir.mktmpdir do |dir|
        result = dm.snapshot_download("data", dir)
        expect(result[:files_downloaded]).to eq(1)
      end
    end
  end
end
