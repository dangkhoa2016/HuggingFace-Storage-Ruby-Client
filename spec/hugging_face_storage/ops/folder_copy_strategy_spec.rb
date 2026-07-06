# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::CrossRepoCopyService::FolderCopyStrategy do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:source_iterator) { instance_double(HuggingFaceStorage::SourceIterator) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:strategy) do
    described_class.new(api_client: api_client, source_iterator: source_iterator, logger: logger)
  end

  describe "#call" do
    let(:folders) do
      [{ source_type: "model", source_repo: "user/repo", source_path: "models", destination: "dst/" }]
    end
    let(:builder) { instance_double(HuggingFaceStorage::CopyPlanBuilder) }
    let(:result) { { copy_ops: [], pending_downloads: [], file_count: 3 } }

    it "normalizes destinations and processes folder sources" do
      allow(source_iterator).to receive(:iterate_and_classify)
        .and_yield(builder, folders.first)
        .and_return([[], [], [result]])
      allow(builder).to receive(:process_source).with(hash_including(source_type: "model")).and_return(result)
      allow(source_iterator).to receive(:wrap_source_result).and_return(result)
      output = strategy.call(folders: folders, cancel_token: nil)
      expect(output[:results]).to eq([result])
    end
  end
end
