# frozen_string_literal: true

RSpec.shared_context "with directory manager services" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:get_paginated).and_return([])
      allow(a).to receive(:head).and_raise(HuggingFaceStorage::NotFoundError, "not found")
      allow(a).to receive(:post).and_return([])
      allow(a).to receive(:list_repo_files).and_return([])
      allow(a).to receive(:download_repo_file).and_return("file content".b)
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_bytes_to_path)
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc", size: 10 })
      allow(x).to receive(:upload_batch).and_return([])
      allow(x).to receive(:stream_download_and_upload)
    end
  end
  let(:downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_file)
    end
  end
  let(:file_manager) do
    instance_double(HuggingFaceStorage::FileManager).tap do |fm|
      allow(fm).to receive(:exists?).and_return(false)
      allow(fm).to receive(:delete)
      allow(fm).to receive(:list).and_return([])
      allow(fm).to receive(:copy_from)
    end
  end

  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:crud_service) { HuggingFaceStorage::DirectoryCrudService.new(api_client: api, xet_uploader: uploader, file_manager: file_manager, bucket_id: bucket_id, logger: logger, config: config) }
  let(:transfer_service) { HuggingFaceStorage::DirectoryTransferService.new(api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager, bucket_id: bucket_id, logger: logger, config: config) }
  let(:copy_pipeline) { HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger, config: config) }
  let(:same_bucket_copy) { HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, file_manager: file_manager, logger: logger, config: config, copy_pipeline: copy_pipeline) }
  let(:source_iterator) { HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger) }
  let(:cross_repo_copy) { HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: file_manager, copy_pipeline: copy_pipeline, bucket_id: bucket_id, source_iterator: source_iterator, logger: logger) }
  let(:dir_copy_service) { HuggingFaceStorage::DirectoryCopyService.new(same_bucket_copy: same_bucket_copy, cross_repo_copy: cross_repo_copy, copy_pipeline: copy_pipeline, logger: logger, config: config) }
  let(:dm) do
    described_class.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader, file_manager: file_manager,
      bucket_id: bucket_id, logger: logger,
      crud_service: crud_service, transfer_service: transfer_service, copy_service: dir_copy_service
    )
  end
end
