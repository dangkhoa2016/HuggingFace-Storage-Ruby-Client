# frozen_string_literal: true

require "spec_helper"
require_relative "../../../src/hugging_face_storage/xet/gearhash_table"

RSpec.describe HuggingFaceStorage do
  it "defines GEARHASH_TABLE as an Array" do
    expect(described_class::GEARHASH_TABLE).to be_an(Array)
  end

  it "contains exactly 256 elements" do
    expect(described_class::GEARHASH_TABLE.size).to eq(256)
  end

  it "contains only Integer values" do
    expect(described_class::GEARHASH_TABLE).to all(be_an(Integer))
  end

  it "is frozen" do
    expect(described_class::GEARHASH_TABLE).to be_frozen
  end
end
