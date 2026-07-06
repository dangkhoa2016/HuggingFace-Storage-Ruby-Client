# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileManager do
  include_context "with null logger"
  include_context "with file manager services"

  describe "debug mode" do
    it "hides backtrace when debug_mode=false (default)" do
      allow(api).to receive(:post)
        .with("/api/models/org/r/paths-info/main", hash_including(body: { paths: ["f.bin"] }))
        .and_return([])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      expect {
        fm.copy_file(source_type: "model", source_repo: "org/r",
          source_path: "f.bin", destination: "out.bin")
      }.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
        expect(e.backtrace).to eq([])
        expect(e.cause).to be_nil
      end
    end

    it "preserves backtrace when debug_mode=true" do
      dm_cfg = HuggingFaceStorage::Configuration.new(debug_mode: true)
      dm_cp = HuggingFaceStorage::CopyPipeline.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id, logger: logger,
config: dm_cfg)
      dm_sbc = HuggingFaceStorage::SameBucketCopyService.new(api_client: api, bucket_id: bucket_id, logger: logger,
config: dm_cfg)
      dm_si = HuggingFaceStorage::SourceIterator.new(api: api, bucket_id: bucket_id, logger: logger, debug_mode: true)
      dm_crc = HuggingFaceStorage::CrossRepoCopyService.new(api_client: api, file_manager: nil, copy_pipeline: dm_cp, bucket_id: bucket_id,
source_iterator: dm_si, logger: logger)
      dm_cs = HuggingFaceStorage::FileCopyService.new(same_bucket: dm_sbc, cross_repo: dm_crc, copy_pipeline: dm_cp, logger: logger,
config: dm_cfg)
      dm_fm = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader, bucket_id: bucket_id,
        logger: logger,
        upload_service: instance_double(HuggingFaceStorage::FileUploadService),
        delete_service: instance_double(HuggingFaceStorage::FileDeleteService),
        copy_service: dm_cs
      )
      allow(api).to receive(:post)
        .with("/api/models/org/r/paths-info/main", hash_including(body: { paths: ["f.bin"] }))
        .and_return([])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", kind_of(Hash))
        .and_return([])
      allow(api).to receive(:batch)

      expect {
        dm_fm.copy_file(source_type: "model", source_repo: "org/r",
          source_path: "f.bin", destination: "out.bin")
      }.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
        expect(e.backtrace).not_to be_empty
        expect(e.cause).to be_nil
      end
    end
  end

  describe "custom Configuration" do
    it "respects custom delete_batch_size" do
      config = HuggingFaceStorage::Configuration.new(delete_batch_size: 2)
      custom_delete_service = HuggingFaceStorage::FileDeleteService.new(api_client: api, bucket_id: bucket_id, config: config,
logger: logger)
      custom_fm = described_class.new(api_client: api, xet_uploader: uploader, xet_downloader: downloader, bucket_id: bucket_id, logger: logger, config: config,
                                       upload_service: upload_service, delete_service: custom_delete_service, copy_service: copy_service)

      paths = %w[a.txt b.txt c.txt]
      allow(api).to receive(:post).with(/paths-info/, anything) { |_, body:|
        body[:paths].map { |p| { "type" => "file", "path" => p, "size" => 1, "xetHash" => "h" } }
      }
      batch_calls = []
      allow(api).to receive(:batch) do |_, ops, **|
        batch_calls << ops
        HuggingFaceStorage::BatchResult.new
      end

      custom_fm.delete(paths)
      expect(batch_calls.size).to eq(2)
      expect(batch_calls[0].size).to eq(2)
      expect(batch_calls[1].size).to eq(1)
    end
  end
end
