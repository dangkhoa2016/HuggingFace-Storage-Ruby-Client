# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Snapshot do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_paginated).and_return([
        { "type" => "file", "path" => "data/a.txt", "size" => 5, "xetHash" => "h1", "mtime" => "2026-01-01" },
        { "type" => "file", "path" => "data/b.txt", "size" => 10, "xetHash" => "h2", "mtime" => "2026-01-02" }
      ])
    end
  end
  let(:xet_downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_file)
    end
  end
  let(:fm) do
    instance_double(HuggingFaceStorage::FileManager).tap do |f|
      allow(f).to receive(:list).and_return([
        HuggingFaceStorage::FileInfo.new(path: "data/a.txt", size: 5, xet_hash: "h1", mtime: "2026-01-01"),
        HuggingFaceStorage::FileInfo.new(path: "data/b.txt", size: 10, xet_hash: "h2", mtime: "2026-01-02")
      ])
    end
  end
  let(:dm) { instance_double(HuggingFaceStorage::DirectoryManager) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  let(:snapshot) do
    described_class.new(
      api_client: api, xet_downloader: xet_downloader,
      file_manager: fm, directory_manager: dm,
      bucket_id: bucket_id, logger: null_logger
    )
  end

  def stub_download_with_size
    allow(xet_downloader).to receive(:download_file) do |_bid, remote, local_path, **|
      size = yield remote
      FileUtils.mkdir_p(File.dirname(local_path))
      File.write(local_path, "x" * size)
    end
  end

  def count_thread_news
    count = 0
    real_new = Thread.method(:new)
    allow(Thread).to receive(:new) do |*args, &block|
      count += 1
      real_new.call(*args, &block)
    end
    yield
    count
  end

  describe "#download" do
    it "raises NotFoundError when no files found" do
      allow(fm).to receive(:list).and_return([])

      Dir.mktmpdir do |dir|
        expect { snapshot.download("empty", dir) }
          .to raise_error(HuggingFaceStorage::NotFoundError, /No files found/)
      end
    end

    it "downloads files and writes manifest" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          FileUtils.mkdir_p(File.dirname(local_path))
          File.write(local_path, "x" * (remote_path.end_with?("a.txt") ? 5 : 10))
        end

        result = snapshot.download("data", dir)
        expect(result[:files_downloaded]).to eq(2)
        expect(File.exist?(result[:manifest_path])).to be true

        manifest = JSON.parse(File.read(result[:manifest_path]))
        expect(manifest["files"].size).to eq(2)
        expect(manifest["bucket_id"]).to eq(bucket_id)
      end
    end

    it "passes parallel count from config to the directory downloader" do
      config = HuggingFaceStorage::Configuration.new(parallel_downloads: 7)
      custom_snapshot = described_class.new(
        api_client: api, xet_downloader: xet_downloader,
        file_manager: fm, directory_manager: dm,
        bucket_id: bucket_id, logger: null_logger, config: config
      )
      captured_parallel = nil
      fake_dd_class = Class.new do
        define_method(:initialize) { |**_opts| nil }
        define_method(:download) do |_files, _base, _dir, parallel: 4, cancel_token: nil|
          captured_parallel = parallel
          []
        end
      end
      stub_const("HuggingFaceStorage::DirectoryDownloader", fake_dd_class)
      Dir.mktmpdir do |dir|
        custom_snapshot.download("data", dir)
      end
      expect(captured_parallel).to eq(7)
    end

    it "bounds verify_files workers by config.parallel_verify" do
      Dir.mktmpdir do |dir|
        file_entries = 6.times.map do |i|
          HuggingFaceStorage::FileInfo.new(path: "data/f#{i}.txt", size: 5 + i, xet_hash: "h#{i}", mtime: "2026-01-01")
        end
        allow(fm).to receive(:list).and_return(file_entries)
        stub_download_with_size do |remote|
          remote =~ /f(\d)/ ? 5 + Regexp.last_match(1).to_i : 5
        end
        config = HuggingFaceStorage::Configuration.new(parallel_verify: 2)
        custom_snapshot = described_class.new(
          api_client: api, xet_downloader: xet_downloader,
          file_manager: fm, directory_manager: dm,
          bucket_id: bucket_id, logger: null_logger, config: config
        )
        result = custom_snapshot.download("data", dir, verify_content: true)
        manifest = JSON.parse(File.read(result[:manifest_path]))
        worker_threads = count_thread_news { custom_snapshot.verify_files(dir, manifest, verify_content: true) }
        expect(worker_threads).to eq(2)
      end
    end

    it "raises Error when verification fails" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          FileUtils.mkdir_p(File.dirname(local_path))
          File.write(local_path, "wrong_content")
        end

        expect { snapshot.download("data", dir, verify: true) }
          .to raise_error(HuggingFaceStorage::Error, /verification failed/)
      end
    end

    it "passes verification when files match" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          FileUtils.mkdir_p(File.dirname(local_path))
          File.write(local_path, "x" * (remote_path.end_with?("a.txt") ? 5 : 10))
        end

        result = snapshot.download("data", dir, verify: true)
        expect(result[:verified]).to be true
      end
    end

    it "detects missing files during verification" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          if remote_path.end_with?("a.txt")
            FileUtils.mkdir_p(File.dirname(local_path))
            File.write(local_path, "x" * 5)
          end
        end

        expect { snapshot.download("data", dir, verify: true) }
          .to raise_error(HuggingFaceStorage::Error, /verification failed/)
      end
    end

    it "verifies content sha256 on verify_content: true" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          FileUtils.mkdir_p(File.dirname(local_path))
          File.write(local_path, "x" * (remote_path.end_with?("a.txt") ? 5 : 10))
        end

        expect { snapshot.download("data", dir, verify_content: true) }.not_to raise_error
      end
    end

    it "detects content corruption with verify_content: true" do
      Dir.mktmpdir do |dir|
        allow(xet_downloader).to receive(:download_file) do |_bid, remote_path, local_path, **|
          FileUtils.mkdir_p(File.dirname(local_path))
          expected_size = remote_path.end_with?("a.txt") ? 5 : 10
          File.write(local_path, "x" * expected_size)
        end

        result = snapshot.download("data", dir, verify_content: true)

        manifest = JSON.parse(File.read(result[:manifest_path]))
        dir2 = Dir.mktmpdir
        begin
          # Recreate files with same sizes but different content for b.txt
          manifest["files"].each do |entry|
            relative = entry["path"].sub(%r{^data/?}, "")
            local_path = File.join(dir2, relative)
            FileUtils.mkdir_p(File.dirname(local_path))
            char = entry["path"].end_with?("b.txt") ? "y" : "x"
            File.write(local_path, char * entry["size"])
          end

          manifest_path = File.join(dir2, ".huggingface_snapshot.json")
          File.write(manifest_path, JSON.generate(manifest))
          loaded = HuggingFaceStorage::Snapshot.load_manifest(dir2)

          mismatches = snapshot.verify_files(dir2, loaded, verify_content: true)
          expect(mismatches.size).to eq(1)
          expect(mismatches.first[:reason]).to eq("sha256 mismatch")
        ensure
          FileUtils.rm_rf(dir2)
        end
      end
    end
  end

  describe "#verify_files" do
    it "returns empty mismatches when all sizes match and no content verification" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x" * 5)
        File.write(File.join(dir, "b.txt"), "x" * 10)
        manifest = {
          "source_prefix" => "data",
          "files" => [
            { "path" => "data/a.txt", "size" => 5 },
            { "path" => "data/b.txt", "size" => 10 }
          ]
        }
        mismatches = snapshot.verify_files(dir, manifest)
        expect(mismatches).to be_empty
      end
    end

    it "returns mismatches for missing files" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x" * 5)
        manifest = {
          "source_prefix" => "data",
          "files" => [
            { "path" => "data/a.txt", "size" => 5 },
            { "path" => "data/b.txt", "size" => 10 }
          ]
        }
        mismatches = snapshot.verify_files(dir, manifest)
        expect(mismatches.size).to eq(1)
        expect(mismatches.first[:reason]).to eq("missing")
      end
    end

    it "returns mismatches for size differences" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x" * 99)
        manifest = {
          "source_prefix" => "data",
          "files" => [
            { "path" => "data/a.txt", "size" => 100 }
          ]
        }
        mismatches = snapshot.verify_files(dir, manifest)
        expect(mismatches.size).to eq(1)
        expect(mismatches.first[:reason]).to include("size mismatch")
      end
    end

    it "handles nil source_prefix" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x" * 5)
        manifest = {
          "source_prefix" => nil,
          "files" => [
            { "path" => "a.txt", "size" => 5 }
          ]
        }
        mismatches = snapshot.verify_files(dir, manifest)
        expect(mismatches).to be_empty
      end
    end
  end

  describe ".load_manifest" do
    it "returns nil when no manifest exists" do
      Dir.mktmpdir do |dir|
        expect(described_class.load_manifest(dir)).to be_nil
      end
    end

    it "loads manifest from directory" do
      Dir.mktmpdir do |dir|
        manifest = { "bucket_id" => "test/bucket", "files" => [] }
        File.write(File.join(dir, ".huggingface_snapshot.json"), JSON.generate(manifest))
        loaded = described_class.load_manifest(dir)
        expect(loaded["bucket_id"]).to eq("test/bucket")
      end
    end
  end
end
