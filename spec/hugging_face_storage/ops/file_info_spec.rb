# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileInfo do
  subject(:info) do
    described_class.new(path: "models/config.json", size: 660, xet_hash: "3a1f858c", mtime: 1_717_500_000)
  end

  it "exposes path" do
    expect(info.path).to eq("models/config.json")
  end

  it "exposes size" do
    expect(info.size).to eq(660)
  end

  it "exposes xet_hash" do
    expect(info.xet_hash).to eq("3a1f858c")
  end

  it "exposes mtime" do
    expect(info.mtime).to eq(1_717_500_000)
  end

  it "returns basename from name" do
    expect(info.name).to eq("config.json")
  end

  it "returns directory portion" do
    expect(info.directory).to eq("models")
  end

  it "returns nil directory for root files" do
    root = described_class.new(path: "readme.txt", size: 100)
    expect(root.directory).to be_nil
  end

  it "serializes to hash" do
    expect(info.to_h).to eq({
      path: "models/config.json",
      size: 660,
      xet_hash: "3a1f858c",
      mtime: 1_717_500_000
    })
  end

  it "has readable inspect" do
    expect(info.inspect).to include("FileInfo", "models/config.json")
  end

  it "allows nil xet_hash and mtime" do
    minimal = described_class.new(path: "file.bin", size: 100)
    expect(minimal.xet_hash).to be_nil
    expect(minimal.mtime).to be_nil
  end
end
