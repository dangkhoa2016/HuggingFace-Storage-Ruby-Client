# frozen_string_literal: true

RSpec.shared_context "with file manager services" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_write_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999
      )
      allow(a).to receive(:get_xet_read_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_read_abc", expiration: 9999999999
      )
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:get_paginated).and_return([])
      allow(a).to receive(:file_exists?).and_return(false)
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc123", size: 100 })
      allow(x).to receive(:upload_bytes_to_path).and_return({ xet_hash: "def456", size: 11 })
      allow(x).to receive(:upload_batch).and_return([])
      allow(x).to receive(:stream_download_and_upload) do |_, _, **, &block|
        block&.call(->(c) {})
        { remote_path: "large.bin", xet_hash: "abc", size: 200_000 }
      end
    end
  end
  let(:downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_file)
    end
  end

  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:upload_service) { HuggingFaceStorage::FileUploadService.new(xet_uploader: uploader, bucket_id: bucket_id, logger: logger) }
  let(:delete_service) { HuggingFaceStorage::FileDeleteService.new(api_client: api, bucket_id: bucket_id, config: config, logger: logger) }
  let(:copy_pipeline) { HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger, config: config) }
  let(:same_bucket_copy) { HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, logger: logger, config: config) }
  let(:source_iterator) { HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger) }
  let(:cross_repo_copy) { HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: nil, copy_pipeline: copy_pipeline, bucket_id: bucket_id, source_iterator: source_iterator, logger: logger) }
  let(:copy_service) { HuggingFaceStorage::FileCopyService.new(same_bucket: same_bucket_copy, cross_repo: cross_repo_copy, copy_pipeline: copy_pipeline, logger: logger, config: config) }
  let(:fm) do
    described_class.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader,
      bucket_id: bucket_id, logger: logger,
      upload_service: upload_service, delete_service: delete_service,
      copy_service: copy_service
    )
  end
end
