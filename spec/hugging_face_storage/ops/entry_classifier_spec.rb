# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::EntryClassifier do
  describe ".classify" do
    let(:source_type) { "model" }
    let(:source_repo) { "org/repo" }
    let(:revision) { "main" }
    let(:mapper) { ->(entry) { "dst/#{entry[:destination]}" } }

    it "classifies xet entries as copy_ops" do
      entries = [{ source_path: "a.txt", destination: "a.txt" }]
      path_infos = [{ "path" => "a.txt", "type" => "file", "xetHash" => "abc123" }]

      result = described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: mapper, path_infos: path_infos)
      expect(result[:copy_ops].size).to eq(1)
      expect(result[:copy_ops][0][:path]).to eq("dst/a.txt")
      expect(result[:copy_ops][0][:xetHash]).to eq("abc123")
      expect(result[:pending_downloads]).to be_empty
    end

    it "classifies non-xet entries as pending_downloads" do
      entries = [{ source_path: "b.txt", destination: "b.txt" }]
      path_infos = [{ "path" => "b.txt", "type" => "file", "size" => 500 }]

      result = described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: mapper, path_infos: path_infos)
      expect(result[:copy_ops]).to be_empty
      expect(result[:pending_downloads].size).to eq(1)
      expect(result[:pending_downloads][0][:destination]).to eq("dst/b.txt")
    end

    it "raises on LFS files" do
      entries = [{ source_path: "c.bin", destination: "c.bin" }]
      path_infos = [{ "path" => "c.bin", "type" => "file", "lfs" => { "size" => 999 } }]

      result = described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: mapper, path_infos: path_infos)
      expect(result[:lfs_offenders].size).to eq(1)
      expect(result[:lfs_offenders][0][:path]).to eq("c.bin")
    end

    it "raises NotFoundError when source file is missing" do
      entries = [{ source_path: "missing.txt", destination: "missing.txt" }]
      path_infos = []

      expect do
        described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: mapper, path_infos: path_infos)
      end.to raise_error(HuggingFaceStorage::NotFoundError, /missing.txt/)
    end

    it "raises Error when source is a directory" do
      entries = [{ source_path: "folder", destination: "folder" }]
      path_infos = [{ "path" => "folder", "type" => "directory" }]

      expect do
        described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: mapper, path_infos: path_infos)
      end.to raise_error(HuggingFaceStorage::Error, /folder/)
    end

    it "handles entries without source_path key" do
      entries = [{ "path" => "d.txt" }]
      path_infos = [{ "path" => "d.txt", "type" => "file", "xetHash" => "def456" }]

      result = described_class.classify(entries, source_type: source_type, source_repo: source_repo,
                                        revision: revision, destination_mapper: ->(e) { e["path"] },
                                        path_infos: path_infos)
      expect(result[:copy_ops].size).to eq(1)
    end
  end

  describe ".build_copy_op" do
    it "builds a copy operation hash" do
      op = described_class.build_copy_op("dst/path", "xet_hash_123", "model", "org/repo")
      expect(op[:type]).to eq(HuggingFaceStorage::ApiPaths::COPY_FILE)
      expect(op[:path]).to eq("dst/path")
      expect(op[:xetHash]).to eq("xet_hash_123")
      expect(op[:sourceRepoType]).to eq("model")
      expect(op[:sourceRepoId]).to eq("org/repo")
    end
  end

  describe ".resolve_source_path" do
    it "prefers :source_path key" do
      entry = { source_path: "src/path", "path" => "fallback" }
      expect(described_class.resolve_source_path(entry)).to eq("src/path")
    end

    it "falls back to path key" do
      entry = { "path" => "fallback" }
      expect(described_class.resolve_source_path(entry)).to eq("fallback")
    end
  end
end
