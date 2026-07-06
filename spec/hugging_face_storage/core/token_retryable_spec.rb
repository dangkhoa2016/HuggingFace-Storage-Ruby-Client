# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::TokenRetryable do
  subject(:instance) { test_class.new }

  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:logger) { instance_double(HuggingFaceStorage::NullLogger) }
  let(:bucket_id) { "test-user/test-bucket" }

  let(:test_class) do
    Class.new do
      include HuggingFaceStorage::TokenRetryable

      attr_accessor :token_manager, :logger
    end
  end

  before do
    instance.token_manager = token_manager
    instance.logger = logger
    allow(token_manager).to receive(:fetch_read_token).with(bucket_id)
      .and_return({ token: "valid_token" })
    allow(logger).to receive(:warn)
  end

  it "yields the token on success" do
    result = instance.send(:with_token_retry, bucket_id, label: :read) do |token|
      token
    end
    expect(result).to eq("valid_token")
  end

  context "when ApiError with 401 is raised" do
    before do
      call_count = 0
      allow(token_manager).to receive(:fetch_read_token).with(bucket_id) do
        call_count += 1
        call_count == 1 ? { token: "stale_token" } : { token: "refreshed_token" }
      end
      allow(token_manager).to receive(:invalidate_read_token).with(bucket_id)
    end

    it "invalidates token, refetches, and retries" do
      first_attempt = true
      result = instance.send(:with_token_retry, bucket_id, label: :read) do |token|
        if first_attempt
          first_attempt = false
          raise HuggingFaceStorage::ApiError.new(message: "unauthorized", status: 401)
        end
        token
      end

      expect(result).to eq("refreshed_token")
      expect(token_manager).to have_received(:invalidate_read_token).with(bucket_id).once
    end
  end

  context "when ApiError with 403 is raised" do
    before do
      call_count = 0
      allow(token_manager).to receive(:fetch_read_token).with(bucket_id) do
        call_count += 1
        call_count == 1 ? { token: "stale_token" } : { token: "refreshed_token" }
      end
      allow(token_manager).to receive(:invalidate_read_token).with(bucket_id)
    end

    it "invalidates token, refetches, and retries" do
      first_attempt = true
      result = instance.send(:with_token_retry, bucket_id, label: :read) do |token|
        if first_attempt
          first_attempt = false
          raise HuggingFaceStorage::ApiError.new(message: "forbidden", status: 403)
        end
        token
      end

      expect(result).to eq("refreshed_token")
    end
  end

  context "when ApiError with non-auth status" do
    it "raises the error without retrying" do
      expect(token_manager).not_to receive(:invalidate_read_token)

      expect do
        instance.send(:with_token_retry, bucket_id, label: :read) do |_token|
          raise HuggingFaceStorage::ApiError.new(message: "not found", status: 404)
        end
      end.to raise_error(HuggingFaceStorage::ApiError)
    end
  end

  it "supports write label" do
    allow(token_manager).to receive(:fetch_write_token).with(bucket_id)
      .and_return({ token: "write_token" })

    result = instance.send(:with_token_retry, bucket_id, label: :write) do |token|
      token
    end
    expect(result).to eq("write_token")
  end
end
