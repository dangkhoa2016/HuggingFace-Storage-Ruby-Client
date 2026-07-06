# frozen_string_literal: true

RSpec.describe HuggingFaceStorage::CrossRepoCopyService::RepoCopyStrategy do
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:source_iterator) { instance_double(HuggingFaceStorage::SourceIterator) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger, debug: nil, info: nil) }

  subject(:strategy) do
    described_class.new(api_client: api_client, source_iterator: source_iterator, logger: logger)
  end

  describe "#call" do
    let(:sources) { ["path/a"] }
    let(:builder) { instance_double(HuggingFaceStorage::CopyPlanBuilder) }
    let(:result) { { copy_ops: [], pending_downloads: [], file_count: 5 } }

    it "iterates sources and returns ops/results" do
      allow(source_iterator).to receive(:iterate_and_classify).with(sources).and_yield(builder,
"path/a").and_return([[], [], [result]])
      allow(builder).to receive(:process_source).with(
        hash_including(source_type: "model", source_repo: "user/repo"),
        &lambda { |entry|
          expect(entry).to be_a(Hash)
          true
        }
      ).and_return(result)
      allow(source_iterator).to receive(:wrap_source_result).with(result, from: "path/a", to: nil,
source_base: "path/a").and_return(result)

      output = strategy.call(sources: sources, normalized_dst_base: nil, source_type: "model",
                              source_repo: "user/repo", revision: "main", exclude: nil, cancel_token: nil)
      expect(output[:copy_ops]).to eq([])
      expect(output[:results]).to eq([result])
    end
  end
end
