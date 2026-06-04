# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::NullMetricsRegistry do
  subject(:registry) { described_class.new }

  it "returns nil from increment" do
    expect(registry.increment(:counter, 1)).to be_nil
  end

  it "returns nil from gauge" do
    expect(registry.gauge(:temperature, 36.5)).to be_nil
  end

  it "yields and returns block result from measure" do
    expect(registry.measure(:operation) { 42 }).to eq(42)
  end

  it "returns nil from observe" do
    expect(registry.observe(:latency, 0.5)).to be_nil
  end

  it "accepts arbitrary arguments" do
    expect(registry.increment(:counter, 1, extra_arg: true)).to be_nil
  end
end
