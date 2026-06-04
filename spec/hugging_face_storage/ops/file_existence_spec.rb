# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileExistence do
  subject(:checker) { described_class.new(transport: transport, logger: logger) }

  let(:transport) { instance_double(HuggingFaceStorage::HTTPTransport) }
  let(:logger) { null_logger }
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  describe "#file_exists?" do
    it "returns true when HEAD request succeeds" do
      allow(transport).to receive(:request).with(:head, "/buckets/#{bucket_id}/resolve/readme.txt")
      expect(checker.file_exists?(bucket_id, "readme.txt")).to be true
    end

    it "returns false when HEAD returns 404" do
      allow(transport).to receive(:request)
        .with(:head, "/buckets/#{bucket_id}/resolve/missing.txt")
        .and_raise(HuggingFaceStorage::NotFoundError)

      expect(checker.file_exists?(bucket_id, "missing.txt")).to be false
    end

    it "falls back to listing on ApiError" do
      allow(transport).to receive(:request)
        .with(:head, "/buckets/#{bucket_id}/resolve/some_file.txt")
        .and_raise(HuggingFaceStorage::ApiError.new(message: "error", status: 500))

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: ".", recursive: true })
        .and_return("[]")

      expect(checker.file_exists?(bucket_id, "some_file.txt")).to be false
    end
  end

  describe "#list_files" do
    let(:bucket_id) { TestHelpers::BUCKET_ID }

    it "returns file entries from paginated API response" do
      entries = [
        { "type" => "file", "path" => "a.txt" },
        { "type" => "file", "path" => "b.txt" },
        { "type" => "directory", "path" => "subdir" }
      ]
      after_entries = []

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true })
        .and_return(JSON.generate(entries))

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true, after: "subdir" })
        .and_return(JSON.generate(after_entries))

      results = checker.list_files(bucket_id)
      expect(results.size).to eq(2)
      expect(results.map { |f| f["path"] }).to eq(%w[a.txt b.txt])
    end

    it "paginates through all entries" do
      page1 = [
        { "type" => "file", "path" => "a.txt" },
        { "type" => "file", "path" => "b.txt" }
      ]
      page2 = [
        { "type" => "file", "path" => "c.txt" }
      ]

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true })
        .and_return(JSON.generate(page1))

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true, after: "b.txt" })
        .and_return(JSON.generate(page2))

      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true, after: "c.txt" })
        .and_return(JSON.generate([]))

      results = checker.list_files(bucket_id)
      expect(results.size).to eq(3)
    end

    it "returns empty array when no files" do
      allow(transport).to receive(:request)
        .with(:get, "/api/buckets/#{bucket_id}/paths", query: { prefix: "", recursive: true })
        .and_return("[]")

      results = checker.list_files(bucket_id)
      expect(results).to eq([])
    end
  end
end
