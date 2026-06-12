# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/commands/copy_commands"

RSpec.describe HuggingFaceStorage::CliCommands::CopyCommands do
  subject(:commands) { test_class.new(client) }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::CliCommands::CopyCommands

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
  let(:directories) { instance_double(HuggingFaceStorage::DirectoryManager) }
  let(:bucket) { "test-user/test-bucket" }

  before do
    allow(client).to receive(:directories).and_return(directories)
  end

  describe "#copy" do
    context "with same bucket" do
      before do
        allow(directories).to receive(:copy)
      end

      it "delegates to DirectoryManager#copy" do
        commands.copy(bucket, "source/path", "dest/path")
        expect(directories).to have_received(:copy).with("source/path", "dest/path")
      end
    end

    context "with cross-repo copy" do
      before do
        commands.options = { from_repo: "model:org/my-model" }
        allow(directories).to receive(:copy)
      end

      it "passes source_type and source_repo to DirectoryManager#copy" do
        commands.copy(bucket, "source/path", "dest/path")
        expect(directories).to have_received(:copy).with(
          "source/path", "dest/path",
          hash_including(source_type: "model", source_repo: "org/my-model")
        )
      end
    end

    context "with an error" do
      before do
        allow(directories).to receive(:copy).and_raise(HuggingFaceStorage::Error, "copy failed")
      end

      it "calls error with formatted message" do
        allow(HuggingFaceStorage::CLIFormatter).to receive(:format_error).and_return("ERROR: copy failed")
        expect(commands).to receive(:error).with("ERROR: copy failed")
        commands.copy(bucket, "src", "dest")
      end
    end
  end
end
