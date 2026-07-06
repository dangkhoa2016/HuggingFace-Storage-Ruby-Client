# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage do
  describe ".new" do
    it "creates a Client with token, namespace, and bucket" do
      client = described_class.new(token: "hf_test", namespace: "user", bucket: "repo", log_output: StringIO.new)
      expect(client).to be_a(HuggingFaceStorage::Client)
      expect(client.bucket_id).to eq("user/repo")
    end

    it "passes configuration options to the builder" do
      client = described_class.new(
        token: "hf_test", namespace: "user", bucket: "repo",
        log_level: :debug, debug_mode: true, log_output: StringIO.new
      )
      expect(client.debug_mode).to be true
      expect(client.log_level).to eq(:debug)
    end
  end

  describe ".build" do
    it "creates a Client via block-style builder" do
      client = described_class.build do |b|
        b.token = "hf_test"
        b.namespace = "user"
        b.bucket = "repo"
        b.log_output = StringIO.new
      end
      expect(client).to be_a(HuggingFaceStorage::Client)
      expect(client.bucket_id).to eq("user/repo")
    end
  end
end
