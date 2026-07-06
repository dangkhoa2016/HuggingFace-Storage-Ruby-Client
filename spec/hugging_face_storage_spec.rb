# frozen_string_literal: true

RSpec.describe "HuggingFaceStorage smoke test" do
  it "loads without errors" do
    expect(HuggingFaceStorage).to be_a(Module)
  end

  it "has a version" do
    expect(HuggingFaceStorage::VERSION).to be_a(String)
  end
end
