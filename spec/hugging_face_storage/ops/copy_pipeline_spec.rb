# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CopyPipeline do
  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:uploader) { instance_double(HuggingFaceStorage::XetUploader) }
  let(:logger) { null_logger }
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:bucket_id) { "user/bucket" }

  subject(:pipeline) do
    described_class.new(api_client: api, xet_uploader: uploader, bucket_id: bucket_id,
                        logger: logger, config: config)
  end

  describe "#call" do
    it "returns zero result for empty files" do
      result = pipeline.call(files: [])
      expect(result.xet_copied).to eq(0)
      expect(result.files_downloaded).to eq(0)
    end

    it "processes files into copy ops" do
      files = [
        { source_type: "model", source_repo: "org/m", source_path: "a.txt", destination: "dst/a.txt",
          revision: "main" }
      ]
      allow(api).to receive(:post)
        .with("/api/models/org/m/paths-info/main", hash_including(body: { paths: ["a.txt"] }))
        .and_return([{ "path" => "a.txt", "type" => "file", "xetHash" => "abc" }])
      allow(api).to receive(:post)
        .with("/api/buckets/user/bucket/paths-info", hash_including(body: { paths: ["dst/a.txt"] }))
        .and_return([])
      allow(api).to receive(:batch).with(bucket_id, anything, cancel_token: anything,
                                                              raise_on_partial_failure: anything)

      result = pipeline.call(files: files)
      expect(result.xet_copied).to eq(1)
    end

    it "downloads non-xet files" do
      files = [
        { source_type: "model", source_repo: "org/m", source_path: "b.txt", destination: "dst/b.txt",
          revision: "main" }
      ]
      allow(api).to receive(:post)
        .with("/api/models/org/m/paths-info/main", hash_including(body: { paths: ["b.txt"] }))
        .and_return([{ "path" => "b.txt", "type" => "file", "size" => 500 }])
      allow(api).to receive(:post)
        .with("/api/buckets/user/bucket/paths-info", hash_including(body: { paths: ["dst/b.txt"] }))
        .and_return([])

      copier = instance_double(HuggingFaceStorage::RepoFileCopier)
      allow(HuggingFaceStorage::RepoFileCopier).to receive(:new).and_return(copier)
      allow(copier).to receive(:copy)

      result = pipeline.call(files: files)
      expect(result.files_downloaded).to eq(1)
    end
  end

  describe "#execute" do
    it "returns elapsed time and counts" do
      allow(api).to receive(:batch).with(bucket_id, anything, cancel_token: anything,
                                                              raise_on_partial_failure: anything)

      result = pipeline.execute(copy_ops: [{ type: "copyFile", path: "a.txt", xetHash: "x" }],
                                pending_downloads: [])
      expect(result[:xet_copied]).to eq(1)
      expect(result[:files_downloaded]).to eq(0)
      expect(result[:elapsed_ms]).to be_a(Integer)
    end
  end
end
