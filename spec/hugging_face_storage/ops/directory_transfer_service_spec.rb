# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryTransferService do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:get_paginated).and_return([])
      allow(a).to receive(:head).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      allow(a).to receive(:post).and_return([])
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_bytes_to_path)
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc", size: 10 })
      allow(x).to receive(:upload_batch).and_return([])
    end
  end
  let(:downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_file)
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
      api_client: api, xet_uploader: uploader, xet_downloader: downloader,
      file_manager: file_manager, bucket_id: bucket_id, logger: logger
    )
  end

  describe "#download" do
    it "creates DirectoryDownloader and downloads files" do
      files = [
        HuggingFaceStorage::FileInfo.new(path: "models/Qwen/config.json", size: 660),
        HuggingFaceStorage::FileInfo.new(path: "models/Qwen/model.bin", size: 1000)
      ]
      allow(file_manager).to receive(:list)
        .with(prefix: "models/Qwen", recursive: true)
        .and_return(files)

      downloader_instance = instance_double(HuggingFaceStorage::DirectoryDownloader)
      allow(downloader_instance).to receive(:download)
      allow(HuggingFaceStorage::DirectoryDownloader).to receive(:new)
        .with(hash_including(api_client: api, xet_downloader: downloader, bucket_id: bucket_id))
        .and_return(downloader_instance)

      Dir.mktmpdir do |dir|
        result = service.download("models/Qwen", dir)
        expect(result[:directory]).to eq("models/Qwen")
        expect(result[:files_downloaded]).to eq(2)
        expect(result[:local_path]).to eq(dir)
        expect(downloader_instance).to have_received(:download)
          .with(files, "models/Qwen", dir, parallel: 4, cancel_token: nil)
      end
    end

    it "raises NotFoundError for empty directory" do
      expect { service.download("empty", "/tmp/out") }
        .to raise_error(HuggingFaceStorage::NotFoundError, /No files found/)
    end

    it "passes cancel_token to DirectoryDownloader" do
      token = instance_double(HuggingFaceStorage::CancelToken, raise_if_cancelled!: nil)
      allow(file_manager).to receive(:list).and_return([
        HuggingFaceStorage::FileInfo.new(path: "dir/f.txt", size: 10)
      ])

      downloader_instance = instance_double(HuggingFaceStorage::DirectoryDownloader)
      allow(downloader_instance).to receive(:download)
      allow(HuggingFaceStorage::DirectoryDownloader).to receive(:new).and_return(downloader_instance)

      Dir.mktmpdir do |dir|
        service.download("dir", dir, cancel_token: token)
        expect(downloader_instance).to have_received(:download)
          .with(anything, anything, anything, hash_including(cancel_token: token))
      end
    end

    it "passes parallel param to DirectoryDownloader" do
      allow(file_manager).to receive(:list).and_return([
        HuggingFaceStorage::FileInfo.new(path: "dir/f.txt", size: 10)
      ])

      downloader_instance = instance_double(HuggingFaceStorage::DirectoryDownloader)
      allow(downloader_instance).to receive(:download)
      allow(HuggingFaceStorage::DirectoryDownloader).to receive(:new).and_return(downloader_instance)

      Dir.mktmpdir do |dir|
        service.download("dir", dir, parallel: 8)
        expect(downloader_instance).to have_received(:download)
          .with(anything, anything, anything, hash_including(parallel: 8))
      end
    end
  end

  describe "#upload" do
    it "creates DirectoryUploader and uploads files" do
      uploader_instance = instance_double(HuggingFaceStorage::DirectoryUploader)
      allow(uploader_instance).to receive(:upload)
        .and_return({ directory: "remote/dir", files_uploaded: 2, total_size: 100 })
      allow(HuggingFaceStorage::DirectoryUploader).to receive(:new)
        .with(hash_including(api_client: api, xet_uploader: uploader, bucket_id: bucket_id))
        .and_return(uploader_instance)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "content a")
        File.write(File.join(dir, "b.txt"), "content b")

        result = service.upload(dir, "remote/dir")
        expect(result[:files_uploaded]).to eq(2)
        expect(uploader_instance).to have_received(:upload)
          .with(dir, "remote/dir", exclude: nil, cancel_token: nil)
      end
    end

    it "raises Error when local directory does not exist" do
      expect { service.upload("/nonexistent", "remote") }
        .to raise_error(HuggingFaceStorage::Error, /Local directory not found/)
    end

    it "normalizes remote base path" do
      uploader_instance = instance_double(HuggingFaceStorage::DirectoryUploader)
      allow(uploader_instance).to receive(:upload)
      allow(HuggingFaceStorage::DirectoryUploader).to receive(:new).and_return(uploader_instance)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x")
        service.upload(dir, "//remote/path/")
        expect(uploader_instance).to have_received(:upload) do |local, remote, **|
          expect(remote).to eq("remote/path")
        end
      end
    end

    it "passes exclude filter to DirectoryUploader" do
      uploader_instance = instance_double(HuggingFaceStorage::DirectoryUploader)
      allow(uploader_instance).to receive(:upload)
      allow(HuggingFaceStorage::DirectoryUploader).to receive(:new).and_return(uploader_instance)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "keep.txt"), "x")
        service.upload(dir, "remote", exclude: "*.log")
        expect(uploader_instance).to have_received(:upload)
          .with(dir, "remote", exclude: "*.log", cancel_token: nil)
      end
    end

    it "strips trailing slash from local_dir" do
      uploader_instance = instance_double(HuggingFaceStorage::DirectoryUploader)
      allow(uploader_instance).to receive(:upload)
      allow(HuggingFaceStorage::DirectoryUploader).to receive(:new).and_return(uploader_instance)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "x")
        service.upload("#{dir}/", "remote")
        expect(uploader_instance).to have_received(:upload) do |local, _remote, **_|
          expect(local).to eq(dir) # trailing slash removed
        end
      end
    end
  end

  describe "#snapshot_download" do
    it "creates Snapshot and calls download" do
      files = [HuggingFaceStorage::FileInfo.new(path: "data/a.txt", size: 5)]
      allow(file_manager).to receive(:list).and_return(files)

      snapshot_instance = instance_double(HuggingFaceStorage::Snapshot)
      allow(snapshot_instance).to receive(:download)
        .and_return({ directory: "data", local_path: "/tmp/out", files_downloaded: 1 })
      allow(HuggingFaceStorage::Snapshot).to receive(:new)
        .with(hash_including(api_client: api, xet_downloader: downloader,
                             file_manager: file_manager, bucket_id: bucket_id,
                             directory_manager: service))
        .and_return(snapshot_instance)

      Dir.mktmpdir do |dir|
        result = service.snapshot_download("data", dir, verify: false)
        expect(result[:files_downloaded]).to eq(1)
        expect(snapshot_instance).to have_received(:download)
          .with("data", dir, verify: false)
      end
    end

    it "passes verify flag to Snapshot" do
      allow(file_manager).to receive(:list).and_return([
        HuggingFaceStorage::FileInfo.new(path: "data/a.txt", size: 5)
      ])

      snapshot_instance = instance_double(HuggingFaceStorage::Snapshot)
      allow(snapshot_instance).to receive(:download)
      allow(HuggingFaceStorage::Snapshot).to receive(:new).and_return(snapshot_instance)

      Dir.mktmpdir do |dir|
        service.snapshot_download("data", dir, verify: true)
        expect(snapshot_instance).to have_received(:download)
          .with("data", dir, verify: true)
      end
    end
  end
end
