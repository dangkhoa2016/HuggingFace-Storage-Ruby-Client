# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Edge cases across classes" do
  describe "HttpErrorHandler" do
    it "edge: #raise_for_status! returns nil for 2xx status" do
      response = mock_api_response(200, "ok")
      expect(HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)).to be_nil
    end

    it "edge: #raise_for_status! with nil body and non-standard status raises ApiError" do
      response = mock_api_response(499, nil)
      expect do
        HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)
      end.to raise_error(HuggingFaceStorage::ApiError, /HTTP 499/)
    end

    it "edge: #raise_for_status! with empty body and non-standard status raises ApiError" do
      response = mock_api_response(499, "")
      expect do
        HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)
      end.to raise_error(HuggingFaceStorage::ApiError, /HTTP 499/)
    end

    it "edge: #raise_for_status! with malformed JSON body raises ApiError with raw body" do
      response = mock_api_response(499, "{invalid")
      expect do
        HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)
      end.to raise_error(HuggingFaceStorage::ApiError, /{invalid/)
    end

    it "edge: #raise_for_status! with non-standard status 999 raises ApiError" do
      response = mock_api_response(999, "unknown status")
      expect do
        HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)
      end.to raise_error(HuggingFaceStorage::ApiError, /HTTP 999/)
    end

    it "edge: #raise_for_status! with 422 parses validation errors from JSON body" do
      response = mock_api_response(422, JSON.generate({ "errors" => { "field" => "required" } }))
      expect do
        HuggingFaceStorage::HttpErrorHandler.raise_for_status!(response)
      end.to raise_error(HuggingFaceStorage::ValidationError) do |e|
        expect(e.errors).to eq({ "field" => "required" })
      end
    end
  end

  describe "BatchResult" do
    it "edge: empty result reports zero counts and is empty" do
      result = HuggingFaceStorage::BatchResult.new
      expect(result.empty?).to be true
      expect(result.success?).to be true
      expect(result.success_count).to eq(0)
      expect(result.failure_count).to eq(0)
    end

    it "edge: concurrent add_success and add_failure is thread-safe" do
      result = HuggingFaceStorage::BatchResult.new
      threads = 10.times.map do |i|
        Thread.new do
          100.times do
            result.add_success("op_#{i}")
            result.add_failure("fail_#{i}", "err")
          end
        end
      end
      threads.each(&:join)
      expect(result.success_count).to eq(1000)
      expect(result.failure_count).to eq(1000)
    end

    it "edge: raise_if_any! truncates error list to first 5 in message" do
      result = HuggingFaceStorage::BatchResult.new
      10.times { |i| result.add_failure("path#{i}", "error#{i}") }
      expect { result.raise_if_any! }.to raise_error(HuggingFaceStorage::PartialFailureError) do |e|
        expect(e.message).to include("10 operation(s) failed")
      end
    end
  end

  describe "CopyPipeline" do
    let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
    let(:uploader) { instance_double(HuggingFaceStorage::XetUploader) }

    subject(:pipeline) do
      described_class.new(api_client: api, xet_uploader: uploader, bucket_id: "test/test",
                          logger: null_logger)
    end

    it "edge: call with nil files raises error" do
      expect { pipeline.call(files: nil) }.to raise_error(NoMethodError)
    end

    it "edge: call with nil entry in files array raises error" do
      expect { pipeline.call(files: [nil]) }.to raise_error(NoMethodError)
    end

    it "edge: Result data object exposes accessor methods" do
      result = HuggingFaceStorage::CopyPipeline::Result.new(1, 2, 3, 4)
      expect(result.xet_copied).to eq(1)
      expect(result.files_downloaded).to eq(2)
      expect(result.total).to eq(3)
      expect(result.skipped).to eq(4)
    end
  end
end
