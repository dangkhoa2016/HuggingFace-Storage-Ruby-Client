# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Client::ServiceFactory do
  subject(:factory) do
    described_class.new(
      config: config, logger: logger, token: token,
      bucket_id: bucket_id,
      metrics_registry: metrics_registry,
      notifications: notifications
    )
  end

  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:token) { "hf_test_token" }
  let(:bucket_id) { "test-user/test-bucket" }
  let(:metrics_registry) { HuggingFaceStorage::NullMetricsRegistry.instance }
  let(:notifications) { HuggingFaceStorage::NullNotifications.instance }

  describe "#initialize" do
    it "uses NullMetricsRegistry when none provided" do
      f = described_class.new(config: config, logger: logger, token: token, bucket_id: bucket_id)
      expect(f.instance_variable_get(:@metrics_registry)).to be(HuggingFaceStorage::NullMetricsRegistry.instance)
    end

    it "uses NullNotifications when none provided" do
      f = described_class.new(config: config, logger: logger, token: token, bucket_id: bucket_id)
      expect(f.instance_variable_get(:@notifications)).to be(HuggingFaceStorage::NullNotifications.instance)
    end
  end

  describe "#build_auth_and_transport" do
    it "returns auth and api client" do
      auth, api = factory.build_auth_and_transport
      expect(auth).to be_a(HuggingFaceStorage::Authentication)
      expect(api).to be_a(HuggingFaceStorage::ApiClient)
    end
  end

  describe "#build_xet_services" do
    it "returns xet_uploader and xet_downloader" do
      _, api = factory.build_auth_and_transport
      uploader, downloader = factory.build_xet_services(api)
      expect(uploader).to be_a(HuggingFaceStorage::XetUploader)
      expect(downloader).to be_a(HuggingFaceStorage::XetDownloader)
    end
  end

  describe "#build_copy_services" do
    it "returns copy services" do
      _, api = factory.build_auth_and_transport
      uploader, = factory.build_xet_services(api)
      services = factory.build_copy_services(api, uploader)
      expect(services.size).to eq(4)
      expect(services[0]).to be_a(HuggingFaceStorage::SameBucketCopyService)
      expect(services[1]).to be_a(HuggingFaceStorage::CopyPipeline)
      expect(services[2]).to be_a(HuggingFaceStorage::CrossRepoCopyService)
      expect(services[3]).to be_a(HuggingFaceStorage::SourceIterator)
    end
  end

  describe "#build_file_services" do
    it "returns a FileManager" do
      _, api = factory.build_auth_and_transport
      uploader, downloader = factory.build_xet_services(api)
      same_bucket, copy_pipeline, cross_repo, source_iter = factory.build_copy_services(api, uploader)
      file_manager = factory.build_file_services(uploader, downloader, api, same_bucket, cross_repo, copy_pipeline)
      expect(file_manager).to be_a(HuggingFaceStorage::FileManager)
    end
  end

  describe "#build_directory_services" do
    it "returns a DirectoryManager" do
      _, api = factory.build_auth_and_transport
      uploader, downloader = factory.build_xet_services(api)
      same_bucket, copy_pipeline, cross_repo, source_iter = factory.build_copy_services(api, uploader)
      files = factory.build_file_services(uploader, downloader, api, same_bucket, cross_repo, copy_pipeline)
      dir_manager = factory.build_directory_services(api, uploader, downloader, files, copy_pipeline, source_iter)
      expect(dir_manager).to be_a(HuggingFaceStorage::DirectoryManager)
    end
  end
end
