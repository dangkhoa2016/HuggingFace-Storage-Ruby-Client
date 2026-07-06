# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::CrossRepoCopyService::BatchPlanExecutor do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:source_iterator) { instance_double(HuggingFaceStorage::SourceIterator) }
  let(:copy_pipeline) { instance_double(HuggingFaceStorage::CopyPipeline) }
  let(:bucket_id) { "test-bucket" }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:executor) do
    described_class.new(api_client: api_client, source_iterator: source_iterator,
                        copy_pipeline: copy_pipeline, bucket_id: bucket_id, logger: logger)
  end

  describe "#call" do
    it "returns zero result when all ops are skipped" do
      allow(source_iterator).to receive(:skip_existing).and_return([[], [], 5])
      result = executor.call(copy_ops: [{ xet_hash: "abc" }], pending_downloads: [], source_results: [],
                              overwrite: false, cancel_token: nil, label: "Test")
      expect(result[:xet_copied]).to eq(0)
      expect(result[:skipped_files]).to eq(5)
    end

    it "delegates to copy_pipeline when ops exist" do
      allow(source_iterator).to receive(:skip_existing).and_return([[{ xet_hash: "abc" }], [], 0])
      allow(copy_pipeline).to receive(:execute).and_return(xet_copied: 1, files_downloaded: 0, elapsed_ms: 10)
      result = executor.call(copy_ops: [{ xet_hash: "abc" }], pending_downloads: [], source_results: [],
                              overwrite: false, cancel_token: nil, label: "Test")
      expect(result[:xet_copied]).to eq(1)
    end
  end
end
