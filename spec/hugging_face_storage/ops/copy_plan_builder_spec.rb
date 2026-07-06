# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::CopyPlanBuilder do
  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  subject(:builder) do
    described_class.new(api: api, bucket_id: bucket_id, logger: null_logger)
  end

  describe "#process_source" do
    let(:repo_files) do
      [
        { "type" => "file", "path" => "dir/file1.txt", "size" => 100, "xetHash" => "abc123" },
        { "type" => "file", "path" => "dir/file2.txt", "size" => 200, "xetHash" => "def456" },
        { "type" => "directory", "path" => "dir/subdir" }
      ]
    end

    before do
      allow(api).to receive(:list_repo_files).and_return(repo_files)
    end

    context "when source_path is provided" do
      it "builds a default mapper that strips the source_base prefix" do
        result = builder.process_source(
          source_type: "model",
          source_repo: "org/repo",
          source_path: "dir",
          destination: "dest"
        )
        expect(result[:file_count]).to eq(2)
        expect(result[:copy_ops].size).to eq(2)
        expect(result[:copy_ops].first[:path]).to eq("dest/file1.txt")
        expect(result[:copy_ops].last[:path]).to eq("dest/file2.txt")
      end
    end

    context "when source_path is empty" do
      it "builds a default mapper that uses full source paths" do
        result = builder.process_source(
          source_type: "model",
          source_repo: "org/repo",
          source_path: nil,
          destination: "dest"
        )
        expect(result[:file_count]).to eq(2)
        expect(result[:copy_ops].first[:path]).to eq("dest/dir/file1.txt")
      end
    end

    context "when a custom destination_mapper is provided" do
      it "uses the custom mapper instead of building a default" do
        custom = ->(entry) { "custom/#{entry["path"]}" }
        result = builder.process_source(
          source_type: "model",
          source_repo: "org/repo",
          source_path: "dir",
          destination: "dest",
          destination_mapper: custom
        )
        expect(result[:copy_ops].first[:path]).to eq("custom/dir/file1.txt")
      end
    end

    context "when source is not found" do
      it "wraps NotFoundError with a helpful message and preserves cause" do
        original_error = HuggingFaceStorage::NotFoundError.new("Resource not found: 404")
        allow(api).to receive(:list_repo_files).and_raise(original_error)

        expect do
          builder.process_source(
            source_type: "model",
            source_repo: "org/missing",
            source_path: "nonexistent",
            destination: "dest"
          )
        end.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
          expect(e.message).to include("Source path 'nonexistent' not found")
          expect(e.message).to include("org/missing")
          expect(e.cause).to eq(original_error)
        end
      end
    end

    context "when exclude patterns are provided" do
      it "filters out matching files" do
        exclude = ["*.txt"]
        allow(HuggingFaceStorage::ExcludeMatcher).to receive(:match?).and_return(true, false)

        result = builder.process_source(
          source_type: "model",
          source_repo: "org/repo",
          source_path: "dir",
          destination: "dest",
          exclude: exclude
        )
        expect(result[:file_count]).to eq(1)
      end
    end

    context "when no files found after listing" do
      it "raises Error when files list is empty" do
        entries = [{ "type" => "directory", "path" => "dir/subdir" }]
        allow(api).to receive(:list_repo_files).and_return(entries)

        expect do
          builder.process_source(
            source_type: "model",
            source_repo: "org/repo",
            source_path: "dir",
            destination: "dest"
          )
        end.to raise_error(HuggingFaceStorage::Error, /No files found/)
      end
    end

    context "when source_type is bucket" do
      it "uses nil revision for buckets" do
        result = builder.process_source(
          source_type: "bucket",
          source_repo: "user/bucket",
          source_path: "dir",
          destination: "dest"
        )
        expect(result[:file_count]).to eq(2)
        expect(api).to have_received(:list_repo_files).with(
          "bucket", "user/bucket",
          hash_including(revision: nil)
        )
      end
    end

    context "with non-JSON error body" do
      it "wraps NotFoundError preserving plain text detail" do
        original_error = HuggingFaceStorage::NotFoundError.new("Resource not found: some plain text")
        allow(api).to receive(:list_repo_files).and_raise(original_error)

        expect do
          builder.process_source(
            source_type: "model",
            source_repo: "org/repo",
            source_path: "missing",
            destination: "dest"
          )
        end.to raise_error(HuggingFaceStorage::NotFoundError) do |e|
          expect(e.message).to include("some plain text")
          expect(e.cause).to eq(original_error)
        end
      end
    end
  end
end
