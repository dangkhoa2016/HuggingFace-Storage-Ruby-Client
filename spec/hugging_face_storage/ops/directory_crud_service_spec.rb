# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryCrudService do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:head).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      allow(a).to receive(:get_paginated).and_return([])
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:post).and_return([])
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_bytes_to_path)
    end
  end
  let(:file_manager) do
    instance_double(HuggingFaceStorage::FileManager).tap do |fm|
      allow(fm).to receive(:list).and_return([])
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:service) do
    described_class.new(
      api_client: api, xet_uploader: uploader, file_manager: file_manager,
      bucket_id: bucket_id, logger: logger
    )
  end

  describe "#create_directory" do
    it "normalizes path and uploads empty placeholder" do
      result = service.create_directory("new_folder")
      expect(result).to be true
      expect(uploader).to have_received(:upload_bytes_to_path)
        .with(bucket_id, "".b, "new_folder/", cancel_token: nil)
    end

    it "returns true immediately if directory already exists" do
      allow(api).to receive(:head)
        .with("/api/buckets/#{bucket_id}/tree/existing")
        .and_return(double("response"))

      result = service.create_directory("existing")
      expect(result).to be true
      expect(uploader).not_to have_received(:upload_bytes_to_path)
    end

    it "appends trailing slash to normalized path for placeholder" do
      service.create_directory("folder/")
      expect(uploader).to have_received(:upload_bytes_to_path)
        .with(bucket_id, "".b, "folder/", cancel_token: nil)
    end

    it "strips leading slash" do
      service.create_directory("/leading/slash")
      expect(uploader).to have_received(:upload_bytes_to_path)
        .with(bucket_id, "".b, "leading/slash/", cancel_token: nil)
    end
  end

  describe "#delete" do
    it "deletes all files recursively" do
      allow(file_manager).to receive(:list)
        .with(prefix: "dir", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "dir/a.txt", size: 10),
          HuggingFaceStorage::FileInfo.new(path: "dir/b.txt", size: 20)
        ])

      result = service.delete("dir", recursive: true)
      expect(result).to be true
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "dir/a.txt" },
        { type: "deleteFile", path: "dir/b.txt" },
        { type: "deleteFile", path: "dir/" }
      ], hash_including(cancel_token: nil))
    end

    it "raises Error for non-empty directory without recursive flag" do
      allow(file_manager).to receive(:list)
        .with(prefix: "dir", recursive: false)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "dir/file.txt", size: 10)])

      expect { service.delete("dir", recursive: false) }
        .to raise_error(HuggingFaceStorage::Error, /not empty/)
    end

    it "deletes placeholder for empty directory" do
      allow(file_manager).to receive(:list)
        .with(prefix: "empty_dir", recursive: true)
        .and_return([])

      result = service.delete("empty_dir")
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

      result = service.delete(%w[d1 d2], recursive: true)
      expect(result).to be_a(HuggingFaceStorage::BatchResult)
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "deleteFile", path: "d1/f.txt" },
        { type: "deleteFile", path: "d1/" },
        { type: "deleteFile", path: "d2/" }
      ], hash_including(cancel_token: nil))
    end

    it "responds to cancel_token" do
      token = instance_double(HuggingFaceStorage::CancelToken, raise_if_cancelled!: nil)
      allow(file_manager).to receive(:list).and_return([])

      service.delete("empty", cancel_token: token)
      expect(token).to have_received(:raise_if_cancelled!).at_least(:once)
    end
  end

  describe "#exists?" do
    it "returns true when head succeeds" do
      allow(api).to receive(:head)
        .with("/api/buckets/#{bucket_id}/tree/models")
        .and_return(double("response"))

      expect(service.exists?("models")).to be true
    end

    it "returns false when directory is empty and no placeholder" do
      expect(service.exists?("empty_dir")).to be false
    end

    it "returns true when only placeholder exists via paths-info" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", body: { paths: ["my_dir"] })
        .and_return([{ "path" => "my_dir", "type" => "directory", "size" => 0 }])

      expect(service.exists?("my_dir")).to be true
    end

    it "returns false when both head and paths-info raise errors" do
      allow(api).to receive(:post).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      expect(service.exists?("missing")).to be false
    end
  end

  describe "#list" do
    it "returns DirInfo objects for directories only" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree", params: { recursive: "false" })
        .and_return([
          { "type" => "directory", "path" => "models", "uploadedAt" => "2026-01-01" },
          { "type" => "file", "path" => "readme.txt", "size" => 100 },
          { "type" => "directory", "path" => "data", "uploadedAt" => "2026-01-02" }
        ])

      dirs = service.list
      expect(dirs.size).to eq(2)
      expect(dirs[0]).to be_a(HuggingFaceStorage::DirInfo)
      expect(dirs[0].path).to eq("models")
      expect(dirs[1].path).to eq("data")
    end

    it "supports prefix filter" do
      allow(api).to receive(:get_paginated)
        .with("/api/buckets/#{bucket_id}/tree/deepseek-ai", params: { recursive: "false" })
        .and_return([{ "type" => "directory", "path" => "deepseek-ai/R1" }])

      dirs = service.list(prefix: "deepseek-ai")
      expect(dirs.size).to eq(1)
    end

    it "returns empty array when no directories" do
      allow(api).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "readme.md", "size" => 100 }
      ])

      dirs = service.list
      expect(dirs).to be_empty
    end
  end

  describe "#list_files" do
    it "delegates to file_manager.list with prefix and recursive" do
      files = [HuggingFaceStorage::FileInfo.new(path: "Qwen/config.json", size: 660)]
      allow(file_manager).to receive(:list)
        .with(prefix: "Qwen", recursive: true)
        .and_return(files)

      result = service.list_files("Qwen", recursive: true)
      expect(result).to eq(files)
    end

    it "defaults to non-recursive" do
      files = [HuggingFaceStorage::FileInfo.new(path: "Qwen/config.json", size: 660)]
      allow(file_manager).to receive(:list)
        .with(prefix: "Qwen", recursive: false)
        .and_return(files)

      result = service.list_files("Qwen")
      expect(result).to eq(files)
    end
  end

  describe "#metadata" do
    it "returns DirInfo with file count and total size" do
      allow(file_manager).to receive(:list)
        .with(prefix: "models", recursive: true)
        .and_return([
          HuggingFaceStorage::FileInfo.new(path: "models/a.txt", size: 100),
          HuggingFaceStorage::FileInfo.new(path: "models/b.txt", size: 200)
        ])

      info = service.metadata("models")
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
          info = service.metadata("models")
          mutex.synchronize { results << info.file_count }
        end
      end
      threads.each(&:join)
      expect(results).to all(eq(1))
    end

    it "returns zero file_count and total_size for empty directory" do
      allow(file_manager).to receive(:list)
        .with(prefix: "empty", recursive: true)
        .and_return([])

      info = service.metadata("empty")
      expect(info.file_count).to eq(0)
      expect(info.total_size).to eq(0)
    end
  end

  describe "#move" do
    it "moves files with one batch call via paths-info" do
      files = [HuggingFaceStorage::FileInfo.new(path: "old/f1.txt", size: 10),
               HuggingFaceStorage::FileInfo.new(path: "old/f2.txt", size: 20)]
      allow(file_manager).to receive(:list)
        .with(prefix: "old", recursive: true)
        .and_return(files)

      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: %w[old/f1.txt old/f2.txt] }))
        .and_return([
          { "path" => "old/f1.txt", "size" => 10, "xetHash" => "h1" },
          { "path" => "old/f2.txt", "size" => 20, "xetHash" => "h2" }
        ])

      result = service.move("old", "new")
      expect(result[:from]).to eq("old")
      expect(result[:to]).to eq("new")
      expect(result[:files_moved]).to eq(2)
      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "copyFile", path: "new/f1.txt", xetHash: "h1", sourceRepoType: "bucket", sourceRepoId: bucket_id },
        { type: "copyFile", path: "new/f2.txt", xetHash: "h2", sourceRepoType: "bucket", sourceRepoId: bucket_id },
        { type: "deleteFile", path: "old/f1.txt" },
        { type: "deleteFile", path: "old/f2.txt" }
      ])
    end

    it "raises NotFoundError when directory is empty" do
      allow(file_manager).to receive(:list)
        .with(prefix: "empty", recursive: true)
        .and_return([])

      expect { service.move("empty", "new") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /No files found/)
    end

    it "raises NotFoundError when path info is missing" do
      allow(file_manager).to receive(:list)
        .with(prefix: "old", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "old/f.txt", size: 10)])

      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["old/f.txt"] }))
        .and_return([])

      expect { service.move("old", "new") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /File not found/)
    end
  end

  describe "#rename" do
    it "delegates to move" do
      allow(file_manager).to receive(:list)
        .with(prefix: "old", recursive: true)
        .and_return([HuggingFaceStorage::FileInfo.new(path: "old/a.txt", size: 10)])
      allow(api).to receive(:post)
        .and_return([{ "path" => "old/a.txt", "size" => 10, "xetHash" => "h1" }])
      allow(api).to receive(:batch)

      expect(service.rename("old", "new")).to be_a(Hash)
    end
  end
end
