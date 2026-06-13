# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/commands/transfer"

RSpec.describe HuggingFaceStorage::CliCommands::Transfer do
  subject(:commands) { test_class.new(client) }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::CliCommands::Transfer

      attr_accessor :options

      def initialize(client)
        @client = client
        @options = {}
      end

      def shared_client(_bucket)
        @client
      end

      def format_or_say(_result)
        yield
      end

      def say(msg); end
      def error(msg); end
    end
  end

  let(:client) { instance_double(HuggingFaceStorage::Client) }
  let(:files) { instance_double(HuggingFaceStorage::FileManager) }
  let(:directories) { instance_double(HuggingFaceStorage::DirectoryManager) }
  let(:bucket) { "test-user/test-bucket" }

  before do
    allow(client).to receive(:files).and_return(files)
    allow(client).to receive(:directories).and_return(directories)
  end

  describe "#upload" do
    context "with a directory" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with("/tmp/mydir").and_return(true)
        allow(directories).to receive(:upload).and_return({ files_uploaded: 5 })
      end

      it "delegates to DirectoryManager#upload" do
        commands.upload(bucket, "/tmp/mydir", "remote/dir")
        expect(directories).to have_received(:upload).with("/tmp/mydir", "remote/dir", exclude: nil)
      end
    end

    context "with a glob pattern" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with("/tmp/*.txt").and_return(false)
        allow(files).to receive(:upload).and_return(%w[f1 f2])
      end

      it "delegates to FileManager#upload" do
        commands.upload(bucket, "/tmp/*.txt", "remote/")
        expect(files).to have_received(:upload).with("/tmp/*.txt", "remote/", exclude: nil)
      end
    end

    context "with a single file" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with("/tmp/file.txt").and_return(false)
        allow(files).to receive(:upload)
      end

      it "delegates to FileManager#upload" do
        commands.upload(bucket, "/tmp/file.txt", "remote/file.txt")
        expect(files).to have_received(:upload).with("/tmp/file.txt", "remote/file.txt")
      end
    end

    context "when remote_path is nil" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with("/tmp/file.txt").and_return(false)
        allow(files).to receive(:upload)
      end

      it "defaults remote_path to basename of local_path" do
        commands.upload(bucket, "/tmp/file.txt", nil)
        expect(files).to have_received(:upload).with("/tmp/file.txt", "file.txt")
      end
    end

    context "when an error occurs" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with("/tmp/file.txt").and_return(false)
        allow(files).to receive(:upload).and_raise(HuggingFaceStorage::Error, "upload failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: upload failed")
        expect(commands).to receive(:error).with("ERROR: upload failed")
        commands.upload(bucket, "/tmp/file.txt", "remote/file.txt")
      end
    end
  end

  describe "#download" do
    context "when remote path is a file" do
      before do
        allow(files).to receive(:exists?).with("remote/file.txt").and_return(true)
        allow(files).to receive(:download)
      end

      it "delegates to FileManager#download" do
        commands.download(bucket, "remote/file.txt", "/tmp/file.txt")
        expect(files).to have_received(:download).with("remote/file.txt", "/tmp/file.txt")
      end
    end

    context "when remote path is a directory" do
      before do
        allow(files).to receive(:exists?).with("remote/dir").and_return(false)
        allow(directories).to receive(:exists?).with("remote/dir").and_return(true)
        allow(directories).to receive(:download)
      end

      it "delegates to DirectoryManager#download" do
        commands.download(bucket, "remote/dir", "/tmp/dir")
        expect(directories).to have_received(:download).with("remote/dir", "/tmp/dir", parallel: nil)
      end
    end

    context "when remote path is not found" do
      before do
        allow(files).to receive(:exists?).with("missing").and_return(false)
        allow(directories).to receive(:exists?).with("missing").and_return(false)
      end

      it "raises Thor::Error" do
        expect { commands.download(bucket, "missing", "/tmp/out") }
          .to raise_error(Thor::Error, /Not found/)
      end
    end

    context "when a NotFoundError occurs" do
      before do
        allow(files).to receive(:exists?).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      end

      it "calls error with formatted message and hint" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: not found")
        expect(commands).to receive(:error).with("ERROR: not found")
        commands.download(bucket, "remote/file.txt", "/tmp/file.txt")
      end
    end

    context "when an Error occurs" do
      before do
        allow(files).to receive(:exists?).and_raise(HuggingFaceStorage::Error, "generic error")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: generic error")
        expect(commands).to receive(:error).with("ERROR: generic error")
        commands.download(bucket, "remote/file.txt", "/tmp/file.txt")
      end
    end
  end
end
