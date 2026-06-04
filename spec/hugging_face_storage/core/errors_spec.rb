# frozen_string_literal: true

require "spec_helper"

RSpec.describe "HuggingFaceStorage Errors" do
  shared_examples "inherits from Error" do |klass|
    it "#{klass} inherits from Error" do
      expect(klass.ancestors).to include(HuggingFaceStorage::Error)
    end
  end

  it_behaves_like "inherits from Error", HuggingFaceStorage::Error
  it_behaves_like "inherits from Error", HuggingFaceStorage::AuthenticationError
  it_behaves_like "inherits from Error", HuggingFaceStorage::NotFoundError
  it_behaves_like "inherits from Error", HuggingFaceStorage::ConflictError
  it_behaves_like "inherits from Error", HuggingFaceStorage::ApiError

  describe HuggingFaceStorage::Error do
    it "can be raised with a message" do
      expect { raise described_class, "something went wrong" }
        .to raise_error(described_class, "something went wrong")
    end
  end

  describe HuggingFaceStorage::ApiError do
    it "stores status and body" do
      error = described_class.new(message: "failed", status: 500, body: '{"error":"server"}')
      expect(error.status).to eq(500)
      expect(error.body).to eq('{"error":"server"}')
      expect(error.message).to eq("failed")
    end

    it "generates default message" do
      error = described_class.new(status: 422)
      expect(error.message).to eq("API request failed")
    end

    it "stores hint" do
      error = described_class.new(hint: "Try logging in again")
      expect(error.hint).to eq("Try logging in again")
    end
  end
end
