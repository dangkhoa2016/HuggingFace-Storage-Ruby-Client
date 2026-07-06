# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetStreamProcessor do
  subject(:processor) { described_class.new(hasher: hasher, serializer: serializer, logger: logger) }

  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:serializer) { HuggingFaceStorage::XetSerializer.new(hasher) }
  let(:logger) { null_logger }

  describe "#stream_upload" do
    let(:cas_url) { TestHelpers::CAS_URL }
    let(:token) { "test_token" }

    it "streams data and returns hash" do
      stub_request(:post, %r{cas\.huggingface\.co/v1/xorbs})
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      result = processor.stream_upload("remote/test.bin", cas_url: cas_url, token: token) do |write_chunk|
        write_chunk.call("hello streaming upload")
      end

      expect(result[:xet_hash]).to be_a(String)
      expect(result[:size]).to eq("hello streaming upload".bytesize)
      expect(result[:remote_path]).to eq("remote/test.bin")
    end

    it "raises on xorb upload failure" do
      stub_request(:post, %r{cas\.huggingface\.co/v1/xorbs})
        .to_return(status: 400, body: "xorb error")

      expect do
        processor.stream_upload("remote/test.bin", cas_url: cas_url, token: token) do |write_chunk|
          write_chunk.call("data")
        end
      end.to raise_error(HuggingFaceStorage::ApiError, /Xorb upload failed/)
    end

    it "raises on shard upload failure" do
      stub_request(:post, %r{cas\.huggingface\.co/v1/xorbs})
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 400, body: "shard error")

      expect do
        processor.stream_upload("remote/test.bin", cas_url: cas_url, token: token) do |write_chunk|
          write_chunk.call("data")
        end
      end.to raise_error(HuggingFaceStorage::ApiError, /Shard upload failed/)
    end

    it "triggers CDC splits and xorb flush with large data" do
      stub_const("HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS", 1)
      stub_request(:post, %r{cas\.huggingface\.co/v1/xorbs})
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      result = processor.stream_upload("remote/large.bin", cas_url: cas_url, token: token) do |write_chunk|
        write_chunk.call("a" * 200_000)
      end

      expect(result[:xet_hash]).to be_a(String)
      expect(result[:size]).to eq(200_000)
      expect(result[:remote_path]).to eq("remote/large.bin")
    end
  end
end
