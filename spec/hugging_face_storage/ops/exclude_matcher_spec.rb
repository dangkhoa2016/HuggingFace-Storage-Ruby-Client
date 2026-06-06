# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ExcludeMatcher do
  describe ".match?" do
    it "matches glob pattern against full path" do
      expect(described_class.match?("src/main.rb", "*.rb")).to be true
    end

    it "matches basename pattern" do
      expect(described_class.match?("src/main.rb", "main.rb")).to be true
    end

    it "does not match when pattern does not apply" do
      expect(described_class.match?("src/main.rb", "*.py")).to be false
    end

    it "matches nested path with directory glob" do
      expect(described_class.match?("src/main/test.rb", "src/**/*.rb")).to be true
    end

    it "handles string pattern" do
      expect(described_class.match?("file.txt", "*.txt")).to be true
    end

    it "matches any pattern in array" do
      expect(described_class.match?("file.txt", ["*.rb", "*.txt", "*.py"])).to be true
    end

    it "returns false when none of the patterns match" do
      expect(described_class.match?("file.txt", ["*.rb", "*.py"])).to be false
    end

    it "returns false for nil patterns" do
      expect(described_class.match?("file.txt", nil)).to be false
    end

    it "returns false for empty array" do
      expect(described_class.match?("file.txt", [])).to be false
    end
  end
end
