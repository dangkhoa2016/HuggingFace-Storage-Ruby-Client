# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Authentication do
  describe "#initialize" do
    it "accepts a token argument" do
      auth = described_class.new(token: "my_token")
      expect(auth.token).to eq("my_token")
    end

    it "falls back to HF_TOKEN env var" do
      allow(ENV).to receive(:fetch).with("HF_TOKEN", nil).and_return("env_token")
      auth = described_class.new
      expect(auth.token).to eq("env_token")
    end

    it "raises AuthenticationError when no token is provided" do
      allow(ENV).to receive(:[]).with("HF_TOKEN").and_return(nil)
      expect { described_class.new }.to raise_error(HuggingFaceStorage::AuthenticationError, /Token is required/)
    end

    it "raises AuthenticationError when token is empty" do
      expect { described_class.new(token: "") }.to raise_error(HuggingFaceStorage::AuthenticationError)
    end

    it "accepts a TokenProvider" do
      provider = described_class::StaticTokenProvider.new(token: "provider_token")
      auth = described_class.new(token_provider: provider)
      expect(auth.token).to eq("provider_token")
    end

    it "prefers token_provider over token" do
      provider = described_class::StaticTokenProvider.new(token: "from_provider")
      auth = described_class.new(token: "from_token", token_provider: provider)
      expect(auth.token).to eq("from_provider")
    end
  end

  describe "#auth_header" do
    it "returns Bearer authorization header" do
      auth = described_class.new(token: "abc123")
      expect(auth.auth_header).to eq("Authorization" => "Bearer abc123")
    end
  end

  describe HuggingFaceStorage::Authentication::StaticTokenProvider do
    it "returns the token" do
      provider = described_class.new(token: "static_token")
      expect(provider.token).to eq("static_token")
    end

    it "generates auth_header" do
      provider = described_class.new(token: "test_token")
      expect(provider.auth_header).to eq("Authorization" => "Bearer test_token")
    end

    it "raises on empty token" do
      expect { described_class.new(token: "") }.to raise_error(HuggingFaceStorage::AuthenticationError)
    end
  end

  describe HuggingFaceStorage::Authentication::TokenProvider do
    subject(:provider) { described_class.new }

    it "raises NotImplementedError on token" do
      expect { provider.token }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError on auth_header via token" do
      expect { provider.auth_header }.to raise_error(NotImplementedError)
    end
  end
end
