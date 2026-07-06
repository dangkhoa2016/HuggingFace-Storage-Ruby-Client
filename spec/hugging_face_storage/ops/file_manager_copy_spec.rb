# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileManager do
  include_context "with null logger"
  include_context "with file manager services"

  describe "#copy" do
    before do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["source.txt"] }))
        .and_return([{ "path" => "source.txt", "size" => 200, "xetHash" => "sourcehash" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["dest.txt"] }))
        .and_return([])
    end

    it "copies file via batch copyFile" do
      result = fm.copy("source.txt", "dest.txt")
      expect(result[:from]).to eq("source.txt")
      expect(result[:to]).to eq("dest.txt")

      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "dest.txt", xetHash: "sourcehash",
        sourceRepoType: "bucket", sourceRepoId: bucket_id
      }], hash_including(cancel_token: nil))
    end
  end

  describe "#copy_from" do
    it "copies single file from another repo" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["models/config.json"] }))
        .and_return([])

      result = fm.copy_from(
        source_type: "model",
        source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
        source_path: "config.json",
        xet_hash: "3a1f858c",
        destination: "models/config.json"
      )
      expect(result[:to]).to eq("models/config.json")

      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/config.json", xetHash: "3a1f858c",
        sourceRepoType: "model", sourceRepoId: "Qwen/Qwen2.5-0.5B-Instruct"
      }], hash_including(cancel_token: nil))
    end

    it "copies batch of files from another repo" do
      files = [
        { xet_hash: "hash1", destination: "a.txt" },
        { xet_hash: "hash2", destination: "b.txt" }
      ]

      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: hash_including(paths: ["a.txt", "b.txt"])))
        .and_return([])

      result = fm.copy_from(
        source_type: "bucket",
        source_repo: "user/other-bucket",
        files: files
      )
      expect(result[:files_copied]).to eq(2)
    end

    it "raises ArgumentError when xet_hash is missing for single copy" do
      expect {
        fm.copy_from(source_type: "model", source_repo: "repo", destination: "out.txt")
      }.to raise_error(ArgumentError, /xet_hash and destination are required/)
    end

    it "skips batch copy when destination exists and overwrite is false" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: hash_including(paths: ["a.txt", "b.txt"])))
        .and_return([{ "path" => "a.txt", "type" => "file", "size" => 10 }])

      files = [
        { xet_hash: "hash1", destination: "a.txt" },
        { xet_hash: "hash2", destination: "b.txt" }
      ]

      result = fm.copy_from(
        source_type: "bucket", source_repo: "user/other-bucket",
        files: files
      )
      expect(result[:files_copied]).to eq(1)
    end
  end

  describe "#copy_file" do
    it "delegates to copy_files with single entry" do
      allow(api).to receive(:post)
        .with("/api/models/org/repo/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = fm.copy_file(
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

      result = fm.copy_file(
        source_type: "model",
        source_repo: "org/repo",
        source_path: "weights.bin",
        destination: "models/"
      )
      expect(result[:to]).to eq("models/weights.bin")
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "models/weights.bin", xetHash: "hash1",
        sourceRepoType: "model", sourceRepoId: "org/repo"
      }], hash_including(cancel_token: nil))
    end
  end

  describe "#copy_files" do
    it "returns zeros for empty files" do
      result = fm.copy_files(files: [])
      expect(result[:xet_copied]).to eq(0)
      expect(result[:files_downloaded]).to eq(0)
      expect(result[:total]).to eq(0)
    end

    it "copies xet-backed files server-side" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = fm.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/weights.bin"
      }])
      expect(result[:xet_copied]).to eq(1)
      expect(result[:total]).to eq(1)
    end

    it "appends basename for trailing-slash destinations" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      fm.copy_files(files: [{
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
        fm.copy_files(files: [{
          source_type: "model", source_repo: "org/model",
          source_path: "big.bin", destination: "models/big.bin"
        }])
      }.to raise_error(HuggingFaceStorage::Error, /LFS file/)
    end

    it "checks LfsGuard per source group so a clean group is not rejected by prior offenders" do
      allow(api).to receive(:post)
        .with("/api/models/org/a/paths-info/main", hash_including(body: { paths: ["big.bin"] }))
        .and_return([{ "type" => "file", "path" => "big.bin", "size" => 5_000_000_000,
          "lfs" => { "oid" => "abc", "size" => 5_000_000_000, "pointerSize" => 134 } }])
      allow(api).to receive(:post)
        .with("/api/models/org/b/paths-info/main", hash_including(body: { paths: ["small.bin"] }))
        .and_return([{ "type" => "file", "path" => "small.bin", "size" => 100, "xetHash" => "hB" }])
      allow(api).to receive(:batch)

      expect {
        fm.copy_files(files: [
          { source_type: "model", source_repo: "org/a", source_path: "big.bin", destination: "a/big.bin" },
          { source_type: "model", source_repo: "org/b", source_path: "small.bin", destination: "b/small.bin" }
        ])
      }.to raise_error(HuggingFaceStorage::Error, %r{model:org/a})
    end

    it "does not re-check a previous group's LFS offenders under a later group's label" do
      allow(api).to receive(:post)
        .with("/api/models/org/a/paths-info/main", hash_including(body: { paths: ["big.bin"] }))
        .and_return([{ "type" => "file", "path" => "big.bin", "size" => 5_000_000_000,
          "lfs" => { "oid" => "abc", "size" => 5_000_000_000, "pointerSize" => 134 } }])
      allow(api).to receive(:post)
        .with("/api/models/org/b/paths-info/main", hash_including(body: { paths: ["ok.bin"] }))
        .and_return([{ "type" => "file", "path" => "ok.bin", "size" => 50, "xetHash" => "hb" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      checked_labels = []
      fake_guard_class = Class.new do
        define_method(:initialize) { |label| @label = label }
        define_method(:check) do |offenders|
          checked_labels << { label: @label, count: offenders.size }
        end
      end
      stub_const("HuggingFaceStorage::LfsGuard", fake_guard_class)

      fm.copy_files(files: [
        { source_type: "model", source_repo: "org/a", source_path: "big.bin", destination: "a/big.bin" },
        { source_type: "model", source_repo: "org/b", source_path: "ok.bin", destination: "b/ok.bin" }
      ])

      expect(checked_labels).to eq([
        { label: "model:org/a", count: 1 },
        { label: "model:org/b", count: 0 }
      ])
    end

    it "downloads and uploads non-xet files" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["readme.md"] }))
        .and_return([{ "type" => "file", "path" => "readme.md", "size" => 100 }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:download_repo_file)
        .with("model", "org/model", "readme.md", hash_including(revision: "main"))
        .and_return("file content")
      allow(uploader).to receive(:upload_batch)
      allow(api).to receive(:batch)

      result = fm.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "readme.md", destination: "models/readme.md"
      }])
      expect(result[:files_downloaded]).to eq(1)
      expect(uploader).to have_received(:upload_batch)
    end

    it "supports overwrite: true" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["weights.bin"] }))
        .and_return([{ "type" => "file", "path" => "weights.bin", "size" => 100, "xetHash" => "hash1" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      result = fm.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "weights.bin", destination: "models/weights.bin"
      }], overwrite: true)
      expect(result[:skipped]).to eq(0)
    end

    it "supports custom revision for non-bucket sources" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/v2", hash_including(body: { paths: ["config.json"] }))
        .and_return([{ "type" => "file", "path" => "config.json", "size" => 50, "xetHash" => "h2" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      fm.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "config.json", destination: "cfg.json", revision: "v2"
      }])
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "cfg.json", xetHash: "h2",
        sourceRepoType: "model", sourceRepoId: "org/model"
      }], hash_including(cancel_token: nil))
    end

    it "uses nil revision for bucket sources" do
      allow(api).to receive(:post)
        .with("/api/buckets/org/b/paths-info", hash_including(body: { paths: ["data.csv"] }))
        .and_return([{ "type" => "file", "path" => "data.csv", "size" => 200, "xetHash" => "h3" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      fm.copy_files(files: [{
        source_type: "bucket", source_repo: "org/b",
        source_path: "data.csv", destination: "backup/data.csv"
      }])
      expect(api).to have_received(:batch).with(bucket_id, [{
        type: "copyFile", path: "backup/data.csv", xetHash: "h3",
        sourceRepoType: "bucket", sourceRepoId: "org/b"
      }], hash_including(cancel_token: nil))
    end

    it "handles large files via on_large_complete callback" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["large.bin"] }))
        .and_return([{ "type" => "file", "path" => "large.bin", "size" => 200_000 }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:download_repo_file_streaming)
      allow(uploader).to receive(:upload_batch)
      allow(api).to receive(:batch)

      result = fm.copy_files(files: [{
        source_type: "model", source_repo: "org/model",
        source_path: "large.bin", destination: "models/large.bin"
      }])
      expect(result[:files_downloaded]).to eq(1)
    end

    it "detects folder paths and raises Error" do
      allow(api).to receive(:post)
        .with("/api/models/org/model/paths-info/main", hash_including(body: { paths: ["figures"] }))
        .and_return([{ "type" => "directory", "path" => "figures" }])

      expect {
        fm.copy_files(files: [{
          source_type: "model", source_repo: "org/model",
          source_path: "figures", destination: "figures/"
        }])
      }.to raise_error(HuggingFaceStorage::Error, /DirectoryManager/)
    end
  end
end
