# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileManager do
  include_context "with null logger"
  include_context "with file manager services"

  describe "#move" do
    before do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["old/path.txt"] }))
        .and_return([{ "path" => "old/path.txt", "size" => 100, "xetHash" => "hash123" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["new/path.txt"] }))
        .and_return([])
    end

    it "copies then deletes (move operation)" do
      result = fm.move("old/path.txt", "new/path.txt")
      expect(result[:from]).to eq("old/path.txt")
      expect(result[:to]).to eq("new/path.txt")

      expect(api).to have_received(:batch).with(bucket_id, [
        { type: "copyFile", path: "new/path.txt", xetHash: "hash123", sourceRepoType: "bucket",
sourceRepoId: bucket_id },
        { type: "deleteFile", path: "old/path.txt" }
      ], hash_including(cancel_token: nil))
    end
  end

  describe "#move with skip" do
    it "skips when destination exists and overwrite is false" do
      allow(api).to receive(:file_exists?).with(bucket_id, "dest.txt").and_return(true)

      result = fm.move("old.txt", "dest.txt", overwrite: false)
      expect(result[:skipped]).to be true
    end
  end

  describe "#rename" do
    before do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["old_name.txt"] }))
        .and_return([{ "path" => "old_name.txt", "size" => 50, "xetHash" => "hash456" }])
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["new_name.txt"] }))
        .and_return([])
    end

    it "delegates to move" do
      result = fm.rename("old_name.txt", "new_name.txt")
      expect(result[:from]).to eq("old_name.txt")
      expect(result[:to]).to eq("new_name.txt")
    end
  end
end
