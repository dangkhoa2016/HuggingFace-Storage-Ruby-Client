# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/commands/manage"

RSpec.describe HuggingFaceStorage::CliCommands::Manage do
  subject(:commands) { test_class.new(client) }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::CliCommands::Manage

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
      def ask(msg, limited_to:); end
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

  describe "#delete" do
    context "when force option is set" do
      before do
        commands.options = { force: true }
      end

      context "when path is a file" do
        before do
          allow(files).to receive(:exists?).with("file.txt").and_return(true)
          allow(files).to receive(:delete)
        end

        it "delegates to FileManager#delete" do
          commands.delete(bucket, "file.txt")
          expect(files).to have_received(:delete).with("file.txt")
        end
      end

      context "when path is a directory" do
        before do
          allow(files).to receive(:exists?).with("dir").and_return(false)
          allow(directories).to receive(:delete)
        end

        it "delegates to DirectoryManager#delete with recursive option" do
          commands.delete(bucket, "dir")
          expect(directories).to have_received(:delete).with("dir", hash_including(recursive: nil))
        end
      end
    end

    context "without force option" do
      before do
        commands.options = { force: false }
      end

      it "prompts for confirmation" do
        allow(commands).to receive(:ask).and_return("y")
        allow(files).to receive(:exists?).and_return(true)
        allow(files).to receive(:delete)

        commands.delete(bucket, "file.txt")
        expect(files).to have_received(:delete).with("file.txt")
      end

      it "aborts when answer is no" do
        allow(commands).to receive(:ask).and_return("n")
        expect(files).not_to receive(:delete)
        commands.delete(bucket, "file.txt")
      end
    end

    context "when an error occurs" do
      before do
        commands.options = { force: true }
        allow(files).to receive(:exists?).and_raise(HuggingFaceStorage::Error, "delete failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: delete failed")
        expect(commands).to receive(:error).with("ERROR: delete failed")
        commands.delete(bucket, "file.txt")
      end
    end
  end

  describe "#move" do
    context "when source is a file" do
      before do
        allow(files).to receive(:exists?).with("old.txt").and_return(true)
        allow(files).to receive(:move)
      end

      it "delegates to FileManager#move" do
        commands.move(bucket, "old.txt", "new.txt")
        expect(files).to have_received(:move).with("old.txt", "new.txt")
      end
    end

    context "when source is a directory" do
      before do
        allow(files).to receive(:exists?).with("old_dir").and_return(false)
        allow(directories).to receive(:move)
      end

      it "delegates to DirectoryManager#move" do
        commands.move(bucket, "old_dir", "new_dir")
        expect(directories).to have_received(:move).with("old_dir", "new_dir")
      end
    end

    context "when an error occurs" do
      before do
        allow(files).to receive(:exists?).and_raise(HuggingFaceStorage::Error, "move failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: move failed")
        expect(commands).to receive(:error).with("ERROR: move failed")
        commands.move(bucket, "src", "dest")
      end
    end
  end

  describe "#list" do
    let(:file_info) do
      HuggingFaceStorage::FileInfo.new(path: "file.txt", size: 100, xet_hash: "abcdef123456", mtime: "2026-01-01")
    end

    before do
      allow(files).to receive(:list).and_return([file_info])
    end

    it "delegates to FileManager#list" do
      commands.list(bucket, "src")
      expect(files).to have_received(:list).with(hash_including(prefix: "src"))
    end

    it "outputs formatted rows" do
      allow(HuggingFaceStorage::CLIFormatter).to receive(:format_output)
      commands.list(bucket)
      expect(HuggingFaceStorage::CLIFormatter).to have_received(:format_output).with(
        array_including(array_including("file.txt", 100, "abcdef123456", "2026-01-01")),
        nil,
        hash_including(headers: %w[path size xet_hash mtime])
      )
    end

    context "when no files found" do
      before do
        allow(files).to receive(:list).and_return([])
      end

      it "says 'No files found'" do
        expect(commands).to receive(:say).with("No files found")
        commands.list(bucket)
      end
    end

    context "with json format" do
      before do
        commands.options = { json: true }
      end

      it "outputs formatted rows in json" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_output)
        commands.list(bucket)
        expect(HuggingFaceStorage::CLIFormatter).to have_received(:format_output).with(
          anything,
          "json",
          anything
        )
      end
    end

    context "when an error occurs" do
      before do
        allow(files).to receive(:list).and_raise(HuggingFaceStorage::Error, "list failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: list failed")
        expect(commands).to receive(:error).with("ERROR: list failed")
        commands.list(bucket)
      end
    end
  end

  describe "#info" do
    context "when no path is given" do
      before do
        allow(client).to receive(:bucket_info).and_return({ "name" => "my-bucket" })
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_json).and_return("{\"name\":\"my-bucket\"}")
      end

      it "shows bucket info" do
        expect(commands).to receive(:say).with("{\"name\":\"my-bucket\"}")
        commands.info(bucket)
        expect(client).to have_received(:bucket_info)
      end
    end

    context "when path is a file" do
      let(:file_meta) { HuggingFaceStorage::FileInfo.new(path: "f.txt", size: 100) }

      before do
        allow(files).to receive(:exists?).with("f.txt").and_return(true)
        allow(files).to receive(:metadata).and_return(file_meta)
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_json).and_return("{\"path\":\"f.txt\"}")
      end

      it "shows file metadata" do
        expect(commands).to receive(:say).with("{\"path\":\"f.txt\"}")
        commands.info(bucket, "f.txt")
        expect(files).to have_received(:metadata).with("f.txt")
      end
    end

    context "when path is a directory" do
      let(:dir_meta) { HuggingFaceStorage::DirInfo.new(path: "dir", file_count: 3, total_size: 500) }

      before do
        allow(files).to receive(:exists?).with("dir").and_return(false)
        allow(directories).to receive(:metadata).and_return(dir_meta)
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_json).and_return("{\"path\":\"dir\"}")
      end

      it "shows directory metadata" do
        expect(commands).to receive(:say).with("{\"path\":\"dir\"}")
        commands.info(bucket, "dir")
        expect(directories).to have_received(:metadata).with("dir")
      end
    end

    context "when an error occurs" do
      before do
        allow(client).to receive(:bucket_info).and_raise(HuggingFaceStorage::Error, "info failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: info failed")
        expect(commands).to receive(:error).with("ERROR: info failed")
        commands.info(bucket)
      end
    end
  end
end
