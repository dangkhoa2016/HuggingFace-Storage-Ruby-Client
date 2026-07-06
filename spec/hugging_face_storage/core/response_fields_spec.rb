# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ResponseFields do
  it "defines TYPE" do
    expect(described_class::TYPE).to eq("type")
  end

  it "defines PATH" do
    expect(described_class::PATH).to eq("path")
  end

  it "defines SIZE" do
    expect(described_class::SIZE).to eq("size")
  end

  it "defines XET_HASH" do
    expect(described_class::XET_HASH).to eq("xetHash")
  end

  it "defines MTIME" do
    expect(described_class::MTIME).to eq("mtime")
  end

  it "defines LFS" do
    expect(described_class::LFS).to eq("lfs")
  end

  it "defines FILE_TYPE" do
    expect(described_class::FILE_TYPE).to eq("file")
  end

  it "defines DIR_TYPE" do
    expect(described_class::DIR_TYPE).to eq("directory")
  end
end
