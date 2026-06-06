# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::SourceIterator do
  subject(:iterator) { described_class.new(api: api, bucket_id: bucket_id, logger: logger) }

  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:logger) { null_logger }

  describe "#iterate_and_classify" do
    let(:builder) { instance_double(HuggingFaceStorage::CopyPlanBuilder) }
    let(:sources) { %w[source1 source2] }
    let(:source_result) do
      {
        copy_ops: [{ path: "dest/file1.txt", source: "hash1" }],
        pending_downloads: [{ destination: "dest/file2.txt", source: "hash2" }],
        file_count: 2,
        directories: %w[dir1],
        xet_count: 1,
        download_count: 1,
        metadata: { from: "source1", to: "dest", file_count: 2, directories: %w[dir1], xet_count: 1, download_count: 1 }
      }
    end

    before do
      allow(HuggingFaceStorage::CopyPlanBuilder).to receive(:new).with(
        api: api, bucket_id: bucket_id, logger: logger, debug_mode: false
      ).and_return(builder)
    end

    it "yields each source to the block" do
      yielded = []
      allow(builder).to receive(:process_source).and_return(source_result)

      iterator.iterate_and_classify(sources) do |b, source|
        yielded << source
        source_result
      end

      expect(yielded).to eq(%w[source1 source2])
    end

    it "aggregates copy_ops and pending_downloads" do
      allow(builder).to receive(:process_source).and_return(source_result)

      copy_ops, pending_downloads, results = iterator.iterate_and_classify(sources) do |_b, _s|
        source_result
      end

      expect(copy_ops.size).to eq(2)
      expect(pending_downloads.size).to eq(2)
      expect(results.size).to eq(2)
    end

    it "returns empty arrays when no sources given" do
      copy_ops, pending_downloads, results = iterator.iterate_and_classify([])

      expect(copy_ops).to eq([])
      expect(pending_downloads).to eq([])
      expect(results).to eq([])
    end

    it "logs per-source summary" do
      allow(builder).to receive(:process_source).and_return(source_result)
      allow(logger).to receive(:info)

      iterator.iterate_and_classify(sources) { |_b, _s| source_result }

      expect(logger).to have_received(:info).with(/Source:.*2 file/).twice
      expect(logger).to have_received(:info).with(/Total:.*2 source/)
    end
  end

  describe "#wrap_source_result" do
    let(:raw) do
      {
        copy_ops: [{ path: "f.txt" }],
        pending_downloads: [],
        file_count: 1,
        directories: [],
        xet_count: 1,
        download_count: 0
      }
    end

    it "enriches raw result with metadata" do
      result = iterator.wrap_source_result(raw, from: "model:org/repo", to: "dest", source_base: "src")

      expect(result[:metadata][:from]).to eq("model:org/repo")
      expect(result[:metadata][:to]).to eq("dest")
      expect(result[:metadata][:source_base]).to eq("src")
      expect(result[:copy_ops]).to eq([{ path: "f.txt" }])
    end
  end

  describe "#skip_existing" do
    let(:copy_ops) { [{ path: "existing_file.txt" }, { path: "new_file.txt" }] }
    let(:pending_downloads) { [{ destination: "dl_file.txt" }] }
    let(:source_results) do
      [{ file_count: 3, from: "source1", to: "dest", directories: [], source_base: "src",
         xet_count: 2, download_count: 1 }]
    end

    before do
      allow(HuggingFaceStorage::BucketQuery).to receive(:batch_exists?)
        .and_return(Set.new(%w[existing_file.txt dl_file.txt]))
    end

    it "filters out existing files from copy_ops" do
      filtered_ops, filtered_downloads, skipped = iterator.skip_existing(copy_ops, pending_downloads, source_results)

      expect(filtered_ops.map { |op| op[:path] }).to eq(["new_file.txt"])
      expect(filtered_downloads).to eq([])
      expect(skipped).to eq(2)
    end

    it "returns all operations when none exist" do
      allow(HuggingFaceStorage::BucketQuery).to receive(:batch_exists?)
        .and_return(Set.new)

      filtered_ops, filtered_downloads, skipped = iterator.skip_existing(copy_ops, pending_downloads, source_results)

      expect(filtered_ops.size).to eq(2)
      expect(filtered_downloads.size).to eq(1)
      expect(skipped).to eq(0)
    end

    it "returns early with zero skipped when no operations given" do
      filtered_ops, filtered_downloads, skipped = iterator.skip_existing([], [], source_results)

      expect(filtered_ops).to eq([])
      expect(filtered_downloads).to eq([])
      expect(skipped).to eq(0)
    end

    it "logs skip message when files are skipped" do
      allow(logger).to receive(:info)

      iterator.skip_existing(copy_ops, pending_downloads, source_results)

      expect(logger).to have_received(:info).with(/Skipped 2 file/)
    end

    it "logs nothing to copy when all files are skipped" do
      allow(logger).to receive(:info)
      all_existing_ops = [{ path: "a.txt" }]
      allow(HuggingFaceStorage::BucketQuery).to receive(:batch_exists?)
        .and_return(Set.new(%w[a.txt]))

      iterator.skip_existing(all_existing_ops, [], source_results)

      expect(logger).to have_received(:info).with(/Nothing to copy/)
    end
  end
end
