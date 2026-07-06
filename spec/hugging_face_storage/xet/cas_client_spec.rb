# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CasClient do
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:http_pool) { HuggingFaceStorage::HttpPool.new(config: config, logger: logger) }
  let(:retryable) { HuggingFaceStorage::Retryable.new(logger: logger) }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::CasClient

      attr_reader :logger, :config, :http_pool, :retryable

      def initialize(logger, config, http_pool, retryable)
        @logger = logger
        @config = config
        @http_pool = http_pool
        @retryable = retryable
      end
    end
  end

  subject(:client) { test_class.new(logger, config, http_pool, retryable) }

  let(:hex) { "00" * 32 }

  describe "#upload_xorb" do
    it "uploads and increments metrics" do
      xorb_hash = ("\x00" * 32).b
      stub_request(:post, "https://cas.example.com/v1/xorbs/default/#{hex}")
        .to_return(status: 200, body: "ok")
      allow(client).to receive(:metrics_registry)
        .and_return(instance_double(HuggingFaceStorage::MetricsRegistry, increment: true))

      expect { client.send(:upload_xorb, "https://cas.example.com", "token", xorb_hash, "data") }
        .not_to raise_error
    end
  end

  describe "#upload_shard" do
    it "uploads and increments metrics" do
      stub_request(:post, "https://cas.example.com/v1/shards")
        .to_return(status: 200, body: "ok")
      allow(client).to receive(:metrics_registry)
        .and_return(instance_double(HuggingFaceStorage::MetricsRegistry, increment: true))

      expect { client.send(:upload_shard, "https://cas.example.com", "token", "shard_data") }
        .not_to raise_error
    end
  end

  describe "#cas_post" do
    it "raises ApiError on non-OK response" do
      stub_request(:post, "https://cas.example.com/v1/xorbs/default/#{hex}")
        .to_return(status: 400, body: "server error")

      expect do
        client.send(:cas_post, "https://cas.example.com/v1/xorbs/default/#{hex}", "tok", "data", "Xorb")
      end.to raise_error(HuggingFaceStorage::ApiError, /Xorb upload failed/)
    end

    it "returns successfully on OK response" do
      stub_request(:post, "https://cas.example.com/v1/xorbs/default/#{hex}")
        .to_return(status: 200, body: "ok")

      result = client.send(:cas_post, "https://cas.example.com/v1/xorbs/default/#{hex}", "tok", "data", "Xorb")
      expect(result).to be_nil
    end
  end
end
