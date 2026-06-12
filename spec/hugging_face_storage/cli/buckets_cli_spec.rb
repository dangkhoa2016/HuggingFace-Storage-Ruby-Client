# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/cli"

RSpec.describe HuggingFaceStorage::BucketsCLI do
  describe "list" do
    it "requires namespace when not provided and HF_NAMESPACE unset" do
      env_before = ENV["HF_NAMESPACE"]
      ENV["HF_NAMESPACE"] = nil
      expect { described_class.start(["list"]) }.to output(/NAMESPACE required/).to_stderr
    ensure
      ENV["HF_NAMESPACE"] = env_before
    end

    it "reads namespace from HF_NAMESPACE env" do
      env_before = ENV["HF_NAMESPACE"]
      ENV["HF_NAMESPACE"] = "test-ns"
      client = instance_double(HuggingFaceStorage::Client)
      allow(HuggingFaceStorage).to receive(:new).and_return(client)
      allow(client).to receive(:list_buckets).and_return([
        { "name" => "my-bucket", "createdAt" => "2026-01-01", "id" => "123" }
      ])

      expect { described_class.start(["list"]) }.to output(/my-bucket/).to_stdout
    ensure
      ENV["HF_NAMESPACE"] = env_before
    end

    it "lists buckets with namespace argument" do
      client = instance_double(HuggingFaceStorage::Client)
      allow(HuggingFaceStorage).to receive(:new).and_return(client)
      allow(client).to receive(:list_buckets).and_return([
        { "name" => "my-bucket", "createdAt" => "2026-01-01", "id" => "123" }
      ])

      expect {
        described_class.start(["list", "test-user"])
      }.to output(/my-bucket/).to_stdout
    end
  end

  describe "info" do
    it "shows bucket info" do
      client = instance_double(HuggingFaceStorage::Client)
      allow(HuggingFaceStorage::CLIFormatter).to receive(:build_client).and_return(client)
      allow(client).to receive(:bucket_info).and_return({ "name" => "my-bucket", "size" => 100 })
      allow(HuggingFaceStorage::CLIFormatter).to receive(:format_json).and_return("{\"name\":\"my-bucket\"}")

      expect {
        described_class.start(["info", "test-user/my-bucket"])
      }.to output(/my-bucket/).to_stdout
    end
  end
end
