# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileManager do
  include_context "with null logger"
  include_context "with file manager services"

  describe "#open" do
    it "returns XetLazyFile for remote path" do
      lazy = fm.open("remote/file.txt")
      expect(lazy).to be_a(HuggingFaceStorage::XetLazyFile)
      expect(lazy.path).to eq("remote/file.txt")
    end
  end

  describe "#upload" do
    it "uploads a local file to remote path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "model.bin")
        File.write(path, "model data")

        result = fm.upload(path, "models/model.bin")
        expect(result[:path]).to eq("models/model.bin")
        expect(uploader).to have_received(:upload_file_to_path).with(bucket_id, path, "models/model.bin",
hash_including(on_progress: nil, cancel_token: nil))
      end
    end

    it "raises Error when local file does not exist" do
      expect { fm.upload("/nonexistent/file.bin", "remote.bin") }
        .to raise_error(HuggingFaceStorage::Error, /Local file not found/)
    end
  end

  describe "#upload_bytes" do
    it "uploads raw bytes to remote path" do
      result = fm.upload_bytes("hello world", "notes/readme.txt")
      expect(result[:path]).to eq("notes/readme.txt")
      expect(result[:size]).to eq(11)
      expect(uploader).to have_received(:upload_bytes_to_path).with(bucket_id, "hello world", "notes/readme.txt",
hash_including(on_progress: nil, cancel_token: nil))
    end
  end

  describe "#download" do
    before do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["models/config.json"] }))
        .and_return([{ "path" => "models/config.json", "size" => 660, "xetHash" => "abc" }])
    end

    it "downloads remote file to local path" do
      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "config.json")
        result = fm.download("models/config.json", local_path)
        expect(result).to eq(local_path)
        expect(downloader).to have_received(:download_file).with(bucket_id, "models/config.json", local_path,
hash_including(cancel_token: nil))
      end
    end

    it "raises NotFoundError when file does not exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["missing.txt"] }))
        .and_return([])

      expect { fm.download("missing.txt", "/tmp/out.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end

    it "returns XetLazyFile when local_path is nil" do
      lazy = fm.download("models/config.json")
      expect(lazy).to be_a(HuggingFaceStorage::XetLazyFile)
      expect(lazy.path).to eq("models/config.json")
    end
  end

  describe "#delete" do
    before do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["old.txt"] }))
        .and_return([{ "type" => "file", "path" => "old.txt", "size" => 10, "xetHash" => "x" }])
    end

    it "deletes file via batch API" do
      result = fm.delete("old.txt")
      expect(result).to be true
      expect(api).to have_received(:batch).with(bucket_id, [{ type: "deleteFile", path: "old.txt" }],
hash_including(cancel_token: nil))
    end

    it "raises NotFoundError when file does not exist" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["ghost.txt"] }))
        .and_return([])

      expect { fm.delete("ghost.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end

    it "deletes multiple files when given an array" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["a.txt", "b.txt"] }))
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "x" },
          { "type" => "file", "path" => "b.txt", "size" => 20, "xetHash" => "y" }
        ])

      result = fm.delete(["a.txt", "b.txt"])
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "a.txt" },
        { type: "deleteFile", path: "b.txt" }
      ], hash_including(cancel_token: nil))
    end

    it "splits into multiple batch calls when array exceeds DELETE_BATCH_SIZE" do
      paths = (1..25).map { |i| "f#{i}.txt" }
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }

      batch_calls = []
      allow(api).to receive(:batch) do |_, ops, **|
        batch_calls << ops
        HuggingFaceStorage::BatchResult.new
      end

      result = fm.delete(paths)
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(batch_calls.size).to eq(2)
      expect(batch_calls[0].size).to eq(20)
      expect(batch_calls[1].size).to eq(5)
    end

    it "strips leading slashes from paths" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["file.txt"] }))
        .and_return([{ "type" => "file", "path" => "file.txt", "size" => 10, "xetHash" => "x" }])

      result = fm.delete("/file.txt")
      expect(result).to be true
      expect(api).to have_received(:batch).with(bucket_id, [{ type: "deleteFile", path: "file.txt" }],
hash_including(cancel_token: nil))
    end

    it "raises Error when path is a directory" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["models/assets"] }))
        .and_return([{ "type" => "directory", "path" => "models/assets" }])

      expect { fm.delete("models/assets") }
        .to raise_error(HuggingFaceStorage::Error, /Use client.directories.delete instead/)
    end

    it "raises Error when any path in array is a directory" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["a.txt", "models/assets",
"b.txt"] }))
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "x" },
          { "type" => "directory", "path" => "models/assets" },
          { "type" => "file", "path" => "b.txt", "size" => 20, "xetHash" => "y" }
        ])

      expect { fm.delete(["a.txt", "models/assets", "b.txt"]) }
        .to raise_error(HuggingFaceStorage::Error, /Use client.directories.delete instead/)
    end
  end

  describe "#list" do
    it "returns FileInfo objects for files only" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree", params: { recursive: "false" })
        .and_return([
          { "type" => "file", "path" => "readme.txt", "size" => 100, "xetHash" => "h1" },
          { "type" => "directory", "path" => "models", "uploadedAt" => "2026-01-01" },
          { "type" => "file", "path" => "config.json", "size" => 200, "xetHash" => "h2" }
        ])

      files = fm.list
      expect(files.size).to eq(2)
      expect(files[0]).to be_a(HuggingFaceStorage::FileInfo)
      expect(files[0].path).to eq("readme.txt")
      expect(files[1].path).to eq("config.json")
    end

    it "supports prefix filter" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree/Qwen", params: { recursive: "false" })
        .and_return([{ "type" => "file", "path" => "Qwen/config.json", "size" => 660 }])

      files = fm.list(prefix: "Qwen")
      expect(files.size).to eq(1)
      expect(files[0].path).to eq("Qwen/config.json")
    end

    it "supports recursive listing" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree", params: { recursive: "true" })
        .and_return([
          { "type" => "file", "path" => "a/b/c.txt", "size" => 10 }
        ])

      files = fm.list(recursive: true)
      expect(files.size).to eq(1)
    end

    it "returns an Enumerator when lazy: true" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree", params: { recursive: "false" })
        .and_return([
          { "type" => "file", "path" => "a.txt", "size" => 10, "xetHash" => "ha", "mtime" => "2026-01-01" },
          { "type" => "directory", "path" => "sub" },
          { "type" => "file", "path" => "b.txt", "size" => 20, "xetHash" => "hb", "mtime" => "2026-01-02" }
        ])

      lazy = fm.list(lazy: true)
      expect(lazy).to be_a(Enumerator)

      files = lazy.to_a
      expect(files.size).to eq(2)
      expect(files.map(&:path)).to eq(%w[a.txt b.txt])
    end
  end

  describe "#metadata" do
    it "returns FileInfo for existing file" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["config.json"] }))
        .and_return([{ "path" => "config.json", "size" => 660, "xetHash" => "abc", "mtime" => "2026-01-01" }])

      info = fm.metadata("config.json")
      expect(info).to be_a(HuggingFaceStorage::FileInfo)
      expect(info.path).to eq("config.json")
      expect(info.size).to eq(660)
    end

    it "raises NotFoundError for missing file" do
      allow(api).to receive(:post).and_return([])

      expect { fm.metadata("missing.txt") }
        .to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end

  describe "#exists?" do
    it "returns true when file exists" do
      allow(api).to receive(:file_exists?)
        .with(bucket_id, "readme.txt")
        .and_return(true)

      expect(fm.exists?("readme.txt")).to be true
    end

    it "returns false when file does not exist" do
      allow(api).to receive(:file_exists?)
        .with(bucket_id, "missing.txt")
        .and_return(false)
      expect(fm.exists?("missing.txt")).to be false
    end

    it "returns false on NotFoundError" do
      allow(api).to receive(:file_exists?)
        .with(bucket_id, "missing.txt")
        .and_return(false)
      expect(fm.exists?("missing.txt")).to be false
    end
  end
end
