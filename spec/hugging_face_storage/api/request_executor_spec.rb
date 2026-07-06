# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::ApiClient::RequestExecutor do
  let(:transport) { instance_double(HuggingFaceStorage::HTTPTransport) }
  let(:config) { instance_double(HuggingFaceStorage::Configuration) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil) }
  let(:uri) { URI.parse("https://example.com/api") }
  let(:request) { Net::HTTP::Get.new(uri) }

  subject(:executor) { described_class.new(transport: transport, config: config, logger: logger) }

  describe "#execute" do
    it "returns parsed JSON" do
      response = instance_double(Net::HTTPResponse, body: '{"key":"val"}', code: "200")
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      allow(transport).to receive(:log_request)
      allow(transport).to receive(:log_response)
      allow(transport).to receive(:with_connection).and_yield(http).and_return(response)
      allow(transport).to receive(:retry_with_backoff).and_yield.and_return(response)
      allow(HuggingFaceStorage::HttpErrorHandler).to receive(:raise_for_status!).and_return(response)
      result = executor.execute(uri, request)
      expect(result).to eq("key" => "val")
    end

    it "returns nil on empty body" do
      response = instance_double(Net::HTTPResponse, body: "", code: "200")
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      allow(transport).to receive(:log_request)
      allow(transport).to receive(:log_response)
      allow(transport).to receive(:with_connection).and_yield(http).and_return(response)
      allow(transport).to receive(:retry_with_backoff).and_yield.and_return(response)
      allow(HuggingFaceStorage::HttpErrorHandler).to receive(:raise_for_status!).and_return(response)
      result = executor.execute(uri, request)
      expect(result).to be_nil
    end
  end
end
