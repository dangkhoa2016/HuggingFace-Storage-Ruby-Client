# frozen_string_literal: true

require "spec_helper"

RSpec.describe "FileManager#upload with exclude" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_write_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999
      )
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:file_exists?).and_return(false)
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_file_to_path).and_return({ xet_hash: "abc123", size: 100 })
    end
  end
  let(:downloader) { instance_double(HuggingFaceStorage::XetDownloader) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:config) { HuggingFaceStorage::Configuration.default }
  let(:upload_service) { HuggingFaceStorage::FileUploadService.new(xet_uploader: uploader, bucket_id: bucket_id, logger: logger) }
  let(:delete_service) { instance_double(HuggingFaceStorage::FileDeleteService) }
  let(:copy_service) { instance_double(HuggingFaceStorage::FileCopyService) }
  let(:fm) do
    HuggingFaceStorage::FileManager.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader,
      bucket_id: bucket_id, logger: logger,
      upload_service: upload_service, delete_service: delete_service,
      copy_service: copy_service
    )
  end

  it "uploads files matching glob but excluding patterns" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "app.rb"), "code")
      File.write(File.join(dir, "app_spec.rb"), "test")
      File.write(File.join(dir, "helper.rb"), "helper")

      results = fm.upload("#{dir}/*.rb", "remote/", exclude: "*_spec.rb")
      paths = results.map { |r| r[:path] }

      expect(paths).to include("remote/app.rb")
      expect(paths).to include("remote/helper.rb")
      expect(paths).not_to include("remote/app_spec.rb")
    end
  end

  it "raises Error when no files match pattern" do
    Dir.mktmpdir do |dir|
      expect { fm.upload("#{dir}/*.xyz", "remote/") }
        .to raise_error(HuggingFaceStorage::Error, /No files match/)
    end
  end
end
