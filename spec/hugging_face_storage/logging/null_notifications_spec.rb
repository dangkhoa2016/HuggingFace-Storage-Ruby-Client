# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::NullNotifications do
  subject(:notifications) { described_class.new }

  it "returns nil from subscribe" do
    expect(notifications.subscribe("event") {}).to be_nil
  end

  it "returns nil from publish" do
    expect(notifications.publish("event", {})).to be_nil
  end

  it "returns false from subscribed?" do
    expect(notifications.subscribed?("event")).to be false
  end

  it "accepts arbitrary arguments" do
    expect(notifications.subscribe("event", :extra_arg) {}).to be_nil
    expect(notifications.publish("event", key: "val", extra: true)).to be_nil
  end
end
