# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Cancel integration", :slow do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:api) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: null_logger) }
  let(:base) { TestHelpers::BASE_URL }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let!(:cancel_thread) { [] }

  after {
    cancel_thread.each { |t|
      begin
        t.join(1)
      rescue StandardError
        nil
      end
    }
  }

  describe "batch with cancel_token" do
    it "cancels between batch chunks" do
      token = HuggingFaceStorage::CancelToken.new

      call_count = 0
      stub_request(:post, "#{base}/api/buckets/#{bucket_id}/batch")
        .to_return do |_req|
          call_count += 1
          token.cancel! if call_count >= 1
          { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
        end

      ops = (1..2500).map { |i| { type: "deleteFile", path: "f#{i}.txt" } }

      expect {
        api.batch(bucket_id, ops, cancel_token: token)
      }.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end

  describe "FileManager#download with cancel_token" do
    it "raises CancelledError when token is cancelled" do
      downloader = instance_double(HuggingFaceStorage::XetDownloader)
      start_queue = Queue.new
      done_queue = Queue.new
      allow(downloader).to receive(:download_file) do |_bid, _rp, _lp, cancel_token: nil|
        start_queue.push(nil)
        done_queue.pop
        cancel_token&.raise_if_cancelled!
      end
      uploader = instance_double(HuggingFaceStorage::XetUploader)

      us = instance_double(HuggingFaceStorage::FileUploadService)
      ds = instance_double(HuggingFaceStorage::FileDeleteService)
      cs = instance_double(HuggingFaceStorage::FileCopyService)
      fm = HuggingFaceStorage::FileManager.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader,
        bucket_id: bucket_id, logger: null_logger,
        upload_service: us, delete_service: ds, copy_service: cs
      )

      token = HuggingFaceStorage::CancelToken.new
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["file.txt"] }))
        .and_return([{ "type" => "file", "path" => "file.txt", "size" => 10 }])

      cancel_thread << Thread.new do
        start_queue.pop
        token.cancel!
        done_queue.push(nil)
      end

      expect {
        fm.download("file.txt", "/tmp/out.txt", cancel_token: token)
      }.to raise_error(HuggingFaceStorage::CancelledError)
    end
  end
end
