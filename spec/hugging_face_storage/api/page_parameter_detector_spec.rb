# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::PageParameterDetector do
  subject(:detector) { described_class.new }

  let(:first_uri) { URI.parse("https://huggingface.co/api/list?page=1") }
  let(:next_uri)  { URI.parse("https://huggingface.co/api/list?page=2") }

  it "detects a numeric page parameter" do
    expect(detector.detect(first_uri, next_uri)).to eq(["page", 1])
  end

  it "returns nil when URIs differ in host" do
    different = URI.parse("https://other.example.com/api/list?page=2")
    expect(detector.detect(first_uri, different)).to be_nil
  end

  it "returns nil when URIs differ in path" do
    different = URI.parse("https://huggingface.co/api/other?page=2")
    expect(detector.detect(first_uri, different)).to be_nil
  end

  it "returns nil when no query params differ" do
    same = URI.parse("https://huggingface.co/api/list?page=1")
    expect(detector.detect(first_uri, same)).to be_nil
  end

  it "returns nil when differing param is not numeric" do
    cursor_first = URI.parse("https://huggingface.co/api/list?cursor=abc")
    cursor_next = URI.parse("https://huggingface.co/api/list?cursor=def")
    expect(detector.detect(cursor_first, cursor_next)).to be_nil
  end

  it "returns nil when increment is not +1" do
    skip_first = URI.parse("https://huggingface.co/api/list?page=1")
    skip_next  = URI.parse("https://huggingface.co/api/list?page=3")
    expect(detector.detect(skip_first, skip_next)).to be_nil
  end

  it "detects with non-standard param name" do
    offset_first = URI.parse("https://huggingface.co/api/list?offset=0")
    offset_next  = URI.parse("https://huggingface.co/api/list?offset=1")
    expect(detector.detect(offset_first, offset_next)).to eq(["offset", 0])
  end

  it "returns nil when multiple params differ" do
    multi_first = URI.parse("https://huggingface.co/api/list?page=1&limit=10")
    multi_next  = URI.parse("https://huggingface.co/api/list?page=2&limit=20")
    expect(detector.detect(multi_first, multi_next)).to be_nil
  end
end
