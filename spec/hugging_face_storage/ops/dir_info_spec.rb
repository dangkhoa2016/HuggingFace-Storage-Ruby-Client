# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirInfo do
  subject(:info) do
    described_class.new(path: "models/Qwen", file_count: 10, total_size: 1_048_576, uploaded_at: uploaded_at)
  end

  let(:uploaded_at) { Time.new(2026, 6, 4, 15, 36, 10) }

  it "exposes path" do
    expect(info.path).to eq("models/Qwen")
  end

  it "exposes file_count" do
    expect(info.file_count).to eq(10)
  end

  it "exposes total_size" do
    expect(info.total_size).to eq(1_048_576)
  end

  it "exposes uploaded_at" do
    expect(info.uploaded_at).to eq(uploaded_at)
  end

  it "returns basename from name" do
    expect(info.name).to eq("Qwen")
  end

  it "returns parent directory" do
    expect(info.parent).to eq("models")
  end

  it "returns nil parent for root directories" do
    root = described_class.new(path: "Qwen")
    expect(root.parent).to be_nil
  end

  it "serializes to hash" do
    expect(info.to_h).to eq({
      path: "models/Qwen",
      file_count: 10,
      total_size: 1_048_576,
      uploaded_at: uploaded_at
    })
  end

  it "has readable inspect" do
    expect(info.inspect).to include("DirInfo", "models/Qwen")
  end
end
