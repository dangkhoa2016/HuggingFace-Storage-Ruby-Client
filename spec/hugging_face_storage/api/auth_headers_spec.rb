# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::ApiClient::AuthHeaders do
  subject(:auth_headers) { described_class.new(auth: auth) }

  context "with auth" do
    let(:auth) { instance_double(HuggingFaceStorage::Authentication, auth_header: { "Authorization" => "Bearer token" }) }

    it "returns auth headers with User-Agent" do
      result = auth_headers.call
      expect(result["Authorization"]).to eq("Bearer token")
      expect(result["User-Agent"]).to include("HuggingFaceStorage-Ruby")
    end
  end

  context "without auth" do
    let(:auth) { nil }

    it "returns empty hash" do
      expect(auth_headers.call).to eq({})
    end
  end
end
