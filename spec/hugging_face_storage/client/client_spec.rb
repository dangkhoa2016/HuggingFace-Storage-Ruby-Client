# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Client do
  let(:client) do
    described_class.new(
      token: "hf_test_token",
      namespace: "test-user",
      bucket: "test-bucket",
      log_level: :warn,
      log_output: StringIO.new
    )
  end

  describe "#initialize" do
    it "creates client with file and directory managers" do
      expect(client.files).to be_a(HuggingFaceStorage::FileManager)
      expect(client.directories).to be_a(HuggingFaceStorage::DirectoryManager)
    end

    it "sets bucket_id from namespace and bucket" do
      expect(client.bucket_id).to eq("test-user/test-bucket")
    end

    it "creates a logger" do
      expect(client.logger).to be_a(HuggingFaceStorage::HFLogger)
    end

    it "defaults debug_mode to false" do
      expect(client.debug_mode).to be false
    end

    it "accepts debug_mode: true" do
      c = described_class.new(
        token: "hf_test", namespace: "u", bucket: "b",
        debug_mode: true, log_output: StringIO.new
      )
      expect(c.debug_mode).to be true
    end

    it "raises when namespace is nil" do
      expect { described_class.new(namespace: nil, bucket: "b", log_output: StringIO.new) }
        .to raise_error(ArgumentError, /namespace/)
    end

    it "raises when namespace is empty" do
      expect { described_class.new(namespace: "", bucket: "b", log_output: StringIO.new) }
        .to raise_error(ArgumentError, /namespace/)
    end

    it "raises when bucket is nil" do
      expect { described_class.new(namespace: "u", bucket: nil, log_output: StringIO.new) }
        .to raise_error(ArgumentError, /bucket/)
    end

    it "raises when bucket is empty" do
      expect { described_class.new(namespace: "u", bucket: "", log_output: StringIO.new) }
        .to raise_error(ArgumentError, /bucket/)
    end
  end

  describe "#bucket_info" do
    it "fetches bucket information via API" do
      stub_request(:get, "https://huggingface.co/api/buckets/test-user/test-bucket")
        .to_return(
          status: 200,
          body: '{"id":"test-bucket","totalFiles":42,"size":1048576}',
          headers: { "Content-Type" => "application/json" }
        )

      info = client.bucket_info
      expect(info["id"]).to eq("test-bucket")
      expect(info["totalFiles"]).to eq(42)
    end
  end

  describe "#list_buckets" do
    it "lists all buckets in namespace" do
      stub_request(:get, "https://huggingface.co/api/buckets/test-user")
        .to_return(
          status: 200,
          body: '[{"id":"bucket1"},{"id":"bucket2"}]',
          headers: { "Content-Type" => "application/json" }
        )

      buckets = client.list_buckets
      expect(buckets.size).to eq(2)
    end

    it "accepts custom namespace" do
      stub_request(:get, "https://huggingface.co/api/buckets/other-user")
        .to_return(
          status: 200,
          body: '[{"id":"other-bucket"}]',
          headers: { "Content-Type" => "application/json" }
        )

      buckets = client.list_buckets(namespace: "other-user")
      expect(buckets.size).to eq(1)
    end
  end

  describe "#log_level" do
    it "returns current log level" do
      expect(client.log_level).to eq(:warn)
    end

    it "allows changing log level at runtime" do
      client.log_level = :debug
      expect(client.log_level).to eq(:debug)
    end
  end

  describe "#log_format" do
    it "returns current log format" do
      expect(client.log_format).to eq(:default)
    end

    it "allows changing log format at runtime" do
      client.log_format = :json
      expect(client.log_format).to eq(:json)
    end
  end

  describe "#close" do
    it "closes API connections and logger" do
      expect(client.instance_variable_get(:@api)).to receive(:close_all_connections)
      expect(client.instance_variable_get(:@logger)).to receive(:close)
      client.send(:close)
    end
  end
end

RSpec.describe HuggingFaceStorage do
  describe ".new" do
    it "creates a Client instance" do
      client = described_class.new(
        token: "hf_test",
        namespace: "user",
        bucket: "bucket",
        log_output: StringIO.new
      )
      expect(client).to be_a(HuggingFaceStorage::Client)
    end
  end
end

RSpec.describe "HuggingFaceStorage::VERSION" do
  it "is defined" do
    expect(HuggingFaceStorage::VERSION).to be_a(String)
    expect(HuggingFaceStorage::VERSION).to match(/\d+\.\d+\.\d+/)
  end
end
