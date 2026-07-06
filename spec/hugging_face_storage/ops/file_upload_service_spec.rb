# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe HuggingFaceStorage::FileUploadService do
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }
  let(:xet_uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc123", size: 100 })
      allow(x).to receive(:upload_bytes_to_path).and_return({ xet_hash: "def456", size: 11 })
    end
  end

  subject(:service) { described_class.new(xet_uploader: xet_uploader, bucket_id: bucket_id, logger: logger) }

  describe "#upload" do
    it "uploads a local file to remote path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "model.bin")
        File.write(path, "model data")

        result = service.upload(path, "models/model.bin")
        expect(result[:path]).to eq("models/model.bin")
        expect(result[:local_path]).to eq(path)
        expect(xet_uploader).to have_received(:upload_file_to_path).with(bucket_id, path, "models/model.bin",
          hash_including(on_progress: nil, cancel_token: nil))
      end
    end

    it "raises Error when local file does not exist" do
      expect { service.upload("/nonexistent/file.bin", "remote.bin") }
        .to raise_error(HuggingFaceStorage::Error, /Local file not found/)
    end

    it "forwards cancel_token to xet_uploader" do
      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "f.bin")
        File.write(path, "data")

        service.upload(path, "remote.bin", cancel_token: cancel_token)
        expect(xet_uploader).to have_received(:upload_file_to_path).with(bucket_id, path, "remote.bin",
          hash_including(cancel_token: cancel_token))
      end
    end

    it "raises CancelledError when cancelled before upload" do
      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!).and_raise(HuggingFaceStorage::CancelledError)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "f.bin")
        File.write(path, "data")

        expect { service.upload(path, "remote.bin", cancel_token: cancel_token) }
          .to raise_error(HuggingFaceStorage::CancelledError)
      end
    end

    describe "glob patterns" do
      it "uploads multiple files matching a glob pattern" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "a.txt"), "aaa")
          File.write(File.join(dir, "b.txt"), "bbb")
          File.write(File.join(dir, "c.md"), "ccc")

          results = service.upload("#{dir}/*.txt", "docs/")
          expect(results).to be_an(Array)
          expect(results.size).to eq(2)
          expect(xet_uploader).to have_received(:upload_file_to_path).twice
        end
      end

      it "appends basename when remote_path ends with /" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "notes.txt"), "content")

          results = service.upload("#{dir}/*.txt", "docs/")
          expect(results.first[:path]).to eq("docs/notes.txt")
        end
      end

      it "raises Error when no files match the glob pattern" do
        expect { service.upload("/tmp/opencode/does_not_exist_*.bin", "remote/") }
          .to raise_error(HuggingFaceStorage::Error, /No files match pattern/)
      end

      it "excludes files matching exclude patterns" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "data.bin"), "bin")
          File.write(File.join(dir, "data.txt"), "txt")

          results = service.upload("#{dir}/*", "files/", exclude: "*.txt")
          expect(results.size).to eq(1)
          expect(results.first[:local_path]).to match(/data\.bin$/)
        end
      end
    end
  end

  describe "#upload_bytes" do
    it "uploads raw bytes to remote path" do
      result = service.upload_bytes("hello world", "notes/readme.txt")
      expect(result[:path]).to eq("notes/readme.txt")
      expect(result[:size]).to eq(11)
      expect(xet_uploader).to have_received(:upload_bytes_to_path).with(bucket_id, "hello world", "notes/readme.txt",
        hash_including(on_progress: nil, cancel_token: nil))
    end

    it "forwards cancel_token to xet_uploader" do
      cancel_token = instance_double(HuggingFaceStorage::CancelToken)
      allow(cancel_token).to receive(:raise_if_cancelled!)

      service.upload_bytes("data", "path.bin", cancel_token: cancel_token)
      expect(xet_uploader).to have_received(:upload_bytes_to_path).with(bucket_id, "data", "path.bin",
        hash_including(cancel_token: cancel_token))
    end

    it "reports correct size for binary data" do
      data = "\x00\x01\x02".b
      result = service.upload_bytes(data, "binary.dat")
      expect(result[:size]).to eq(3)
    end
  end
end
