# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage do
  it "defines VERSION as a String" do
    expect(described_class::VERSION).to be_a(String)
  end

  it "matches semantic versioning format" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "is the current version 1.0.0" do
    expect(described_class::VERSION).to eq("1.0.0")
  end
end
