# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/commands/advanced"

RSpec.describe HuggingFaceStorage::CliCommands::Advanced do
  subject(:commands) { test_class.new(client) }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::CliCommands::Advanced

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

  describe "#snapshot" do
    let(:result) { { files_downloaded: 5, manifest_path: "/tmp/manifest.json" } }

    before do
      allow(directories).to receive(:snapshot_download).and_return(result)
    end

    it "delegates to DirectoryManager#snapshot_download with verify option" do
      commands.snapshot(bucket, "remote/dir", "/tmp/local")
      expect(directories).to have_received(:snapshot_download).with(
        "remote/dir", "/tmp/local", hash_including(verify: nil)
      )
    end

    context "when an error occurs" do
      before do
        allow(directories).to receive(:snapshot_download).and_raise(HuggingFaceStorage::Error, "snapshot failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: snapshot failed")
        expect(commands).to receive(:error).with("ERROR: snapshot failed")
        commands.snapshot(bucket, "remote/dir", "/tmp/local")
      end
    end
  end

  describe "#edit" do
    let(:edits_json) { '[{"type":"replace","old":"v1","new":"v2"}]' }

    before do
      commands.options = { edits: edits_json }
      allow(files).to receive(:edit).and_return({ xet_hash: "abc", size: 10 })
    end

    it "parses JSON edits and delegates to FileManager#edit" do
      commands.edit(bucket, "config.json")
      expect(files).to have_received(:edit).with(
        "config.json",
        hash_including(edits: [{ type: "replace", old: "v1", new: "v2" }])
      )
    end

    context "when an error occurs" do
      before do
        allow(files).to receive(:edit).and_raise(HuggingFaceStorage::Error, "edit failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: edit failed")
        expect(commands).to receive(:error).with("ERROR: edit failed")
        commands.edit(bucket, "config.json")
      end
    end
  end
end
