# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileInfo do
  subject(:info) do
    described_class.new(path: "models/config.json", size: 660, xet_hash: "3a1f858c", mtime: "2026-06-04T15:36:10.115Z")
  end

  it "exposes attributes" do
    expect(info.path).to eq("models/config.json")
    expect(info.size).to eq(660)
    expect(info.xet_hash).to eq("3a1f858c")
    expect(info.name).to eq("config.json")
    expect(info.directory).to eq("models")
  end

  it "returns nil directory for root files" do
    expect(described_class.new(path: "readme.txt", size: 100).directory).to be_nil
  end

  it "serializes to hash" do
    expect(info.to_h).to eq({ path: "models/config.json", size: 660, xet_hash: "3a1f858c",
mtime: "2026-06-04T15:36:10.115Z" })
  end

  it "has readable inspect" do
    expect(info.inspect).to include("FileInfo", "models/config.json")
  end
end

RSpec.describe HuggingFaceStorage::DirInfo do
  subject(:info) do
    described_class.new(path: "models/Qwen", file_count: 10, total_size: 1_048_576,
uploaded_at: "2026-06-04T15:36:10.115Z")
  end

  it "exposes attributes" do
    expect(info.path).to eq("models/Qwen")
    expect(info.file_count).to eq(10)
    expect(info.total_size).to eq(1_048_576)
    expect(info.name).to eq("Qwen")
    expect(info.parent).to eq("models")
  end

  it "returns nil parent for root directories" do
    expect(described_class.new(path: "Qwen").parent).to be_nil
  end

  it "serializes to hash" do
    expect(info.to_h).to eq({ path: "models/Qwen", file_count: 10, total_size: 1_048_576,
uploaded_at: "2026-06-04T15:36:10.115Z" })
  end

  it "has readable inspect" do
    expect(info.inspect).to include("DirInfo", "models/Qwen")
  end
end
