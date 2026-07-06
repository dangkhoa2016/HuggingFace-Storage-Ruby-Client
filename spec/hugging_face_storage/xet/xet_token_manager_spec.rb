# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetTokenManager do
  subject(:manager) { described_class.new(api_client: api, logger: null_logger, config: config) }

  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive_messages(
        get_xet_write_token: { endpoint: TestHelpers::CAS_URL, token: "write_token", expiration: 999_999_999_999 },
        get_xet_read_token: { endpoint: TestHelpers::CAS_URL, token: "read_token", expiration: 999_999_999_999 }
      )
    end
  end
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:other_bucket_id) { "other-bucket-123" }

  describe "#invalidate_write_token" do
    it "removes a cached write token" do
      manager.fetch_write_token(bucket_id)
      manager.invalidate_write_token(bucket_id)
      manager.fetch_write_token(bucket_id)
      expect(api).to have_received(:get_xet_write_token).twice
    end
  end

  describe "#invalidate_read_token" do
    it "removes a cached read token" do
      manager.fetch_read_token(bucket_id)
      manager.invalidate_read_token(bucket_id)
      manager.fetch_read_token(bucket_id)
      expect(api).to have_received(:get_xet_read_token).twice
    end
  end

  describe "LRU eviction" do
    let(:config) { HuggingFaceStorage::Configuration.new(xet_token_cache_size: 2) }

    it "evicts oldest write token when cache exceeds max size" do
      allow(api).to receive(:get_xet_write_token).and_return(
        { endpoint: TestHelpers::CAS_URL, token: "token_a", expiration: 999_999_999_999 },
        { endpoint: TestHelpers::CAS_URL, token: "token_b", expiration: 999_999_999_999 },
        { endpoint: TestHelpers::CAS_URL, token: "token_c", expiration: 999_999_999_999 }
      )

      manager.fetch_write_token("bucket_a")
      manager.fetch_write_token("bucket_b")
      manager.fetch_write_token("bucket_c")

      expect(api).to have_received(:get_xet_write_token).exactly(3).times
    end

    it "promotes accessed token to MRU position" do
      allow(api).to receive(:get_xet_write_token).and_return(
        { endpoint: TestHelpers::CAS_URL, token: "token_a", expiration: 999_999_999_999 },
        { endpoint: TestHelpers::CAS_URL, token: "token_b", expiration: 999_999_999_999 },
        { endpoint: TestHelpers::CAS_URL, token: "token_c", expiration: 999_999_999_999 },
        { endpoint: TestHelpers::CAS_URL, token: "token_d", expiration: 999_999_999_999 }
      )

      manager.fetch_write_token("bucket_a")
      manager.fetch_write_token("bucket_b")
      manager.fetch_write_token("bucket_a")
      manager.fetch_write_token("bucket_c")

      expect(api).to have_received(:get_xet_write_token).exactly(3).times
    end
  end

  describe "#fetch_write_token" do
    it "returns a token" do
      token = manager.fetch_write_token(bucket_id)
      expect(token[:token]).to eq("write_token")
    end

    it "returns independent copies so caller mutation does not corrupt cache" do
      first = manager.fetch_write_token(bucket_id)
      first[:token] = "MUTATED"
      first[:custom] = :caller_added

      second = manager.fetch_write_token(bucket_id)
      expect(second[:token]).to eq("write_token")
      expect(second).not_to have_key(:custom)
      expect(api).to have_received(:get_xet_write_token).once
    end

    it "caches and reuses the same token per bucket" do
      manager.fetch_write_token(bucket_id)
      manager.fetch_write_token(bucket_id)
      expect(api).to have_received(:get_xet_write_token).once
    end

    it "refetches when expired" do
      allow(Time).to receive(:now).and_return(0)
      manager.fetch_write_token(bucket_id)
      allow(Time).to receive(:now).and_return(999_999_999_999)
      manager.fetch_write_token(bucket_id)
      expect(api).to have_received(:get_xet_write_token).twice
    end

    it "caches tokens for different buckets independently" do
      token_a = manager.fetch_write_token(bucket_id)
      token_b = manager.fetch_write_token(other_bucket_id)

      expect(token_a[:token]).to eq("write_token")
      expect(token_b[:token]).to eq("write_token")
      expect(api).to have_received(:get_xet_write_token).twice
    end

    it "reuses cached token after fetching for another bucket" do
      manager.fetch_write_token(bucket_id)
      manager.fetch_write_token(other_bucket_id)
      manager.fetch_write_token(bucket_id)

      expect(api).to have_received(:get_xet_write_token).twice
    end
  end

  describe "#fetch_read_token" do
    it "returns a token" do
      token = manager.fetch_read_token(bucket_id)
      expect(token[:token]).to eq("read_token")
    end

    it "returns independent copies so caller mutation does not corrupt cache" do
      first = manager.fetch_read_token(bucket_id)
      first[:token] = "MUTATED"
      first[:custom] = :caller_added

      second = manager.fetch_read_token(bucket_id)
      expect(second[:token]).to eq("read_token")
      expect(second).not_to have_key(:custom)
      expect(api).to have_received(:get_xet_read_token).once
    end

    it "caches and reuses the same token per bucket" do
      manager.fetch_read_token(bucket_id)
      manager.fetch_read_token(bucket_id)
      expect(api).to have_received(:get_xet_read_token).once
    end

    it "caches tokens for different buckets independently" do
      manager.fetch_read_token(bucket_id)
      manager.fetch_read_token(other_bucket_id)

      expect(api).to have_received(:get_xet_read_token).twice
    end

    it "reuses cached token after fetching for another bucket" do
      manager.fetch_read_token(bucket_id)
      manager.fetch_read_token(other_bucket_id)
      manager.fetch_read_token(bucket_id)

      expect(api).to have_received(:get_xet_read_token).twice
    end
  end
end
