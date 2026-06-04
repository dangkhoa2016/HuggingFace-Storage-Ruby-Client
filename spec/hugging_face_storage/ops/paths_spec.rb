# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Paths do
  describe ".normalize" do
    it "removes leading slashes" do
      expect(described_class.normalize("/foo/bar")).to eq("foo/bar")
    end

    it "removes trailing slashes" do
      expect(described_class.normalize("foo/bar/")).to eq("foo/bar")
    end
  end

  describe ".strip_leading_slash" do
    it "removes leading slashes" do
      expect(described_class.strip_leading_slash("///foo")).to eq("foo")
    end
  end

  describe ".encode_segments" do
    it "URI encodes each path segment with %20 for spaces" do
      result = described_class.encode_segments("my dir/file name.txt")
      expect(result).to eq("my%20dir/file%20name.txt")
    end

    it "handles special characters" do
      result = described_class.encode_segments("a/b%c/d e")
      expect(result).to eq("a/b%25c/d%20e")
    end
  end
end
