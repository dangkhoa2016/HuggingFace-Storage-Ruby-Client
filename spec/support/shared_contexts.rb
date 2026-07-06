# frozen_string_literal: true

RSpec.shared_context "with api client" do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
end

RSpec.shared_context "with mocked logger" do
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil, warn: nil, error: nil) }
end

RSpec.shared_context "with null logger" do
  let(:null_logger) { HuggingFaceStorage::NullLogger.new }
end

RSpec.shared_context "with http stubs" do
  let(:http_response_200) do
    instance_double(Net::HTTPResponse, code: "200", body: "").tap do |resp|
      allow(resp).to receive(:[]).and_return(nil)
    end
  end

  let(:http_double) do
    double("http").tap { |d| allow(d).to receive(:request).and_return(http_response_200) }
  end

  let(:http_pool) do
    instance_double(HuggingFaceStorage::HttpPool).tap do |pool|
      allow(pool).to receive(:with_connection).and_yield(http_double).and_return(http_response_200)
    end
  end

  let(:retryable) do
    instance_double(HuggingFaceStorage::Retryable).tap do |r|
      allow(r).to receive(:retry_with_backoff).and_yield(0).and_return(http_response_200)
    end
  end
end
