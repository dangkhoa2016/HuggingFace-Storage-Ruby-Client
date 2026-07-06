# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Colorize do
  describe ".colorize_message" do
    before { described_class.clear_cache }

    it "adds ANSI color codes to a highlighted message" do
      result = described_class.colorize_message("INFO", "Download complete: 5 file(s)")
      expect(result).to include(HuggingFaceStorage::Color::RESET)
    end

    it "applies dim style for DEBUG level" do
      result = described_class.colorize_message("DEBUG", "some debug message")
      expect(result).to include(HuggingFaceStorage::Color::DIM)
    end

    it "returns unmodified message when no patterns match" do
      result = described_class.colorize_message("INFO", "plain message")
      expect(result).to eq("plain message")
    end

    it "highlights HTTP status codes" do
      result = described_class.colorize_message("INFO", "HTTP 404 Not Found")
      expect(result).to include(HuggingFaceStorage::Color::BRIGHT_RED)
    end

    it "highlights file sizes" do
      result = described_class.colorize_message("INFO", "Downloaded 1.5 MB")
      expect(result).to include(HuggingFaceStorage::Color::BRIGHT_YELLOW)
    end

    it "highlights duration values" do
      result = described_class.colorize_message("INFO", "Completed in 42 ms")
      expect(result).to include(HuggingFaceStorage::Color::BRIGHT_MAGENTA)
    end

    it "caches results" do
      cache_size_before = described_class.cache_size
      described_class.colorize_message("INFO", "cached message: 5 file(s)")
      described_class.colorize_message("INFO", "cached message: 5 file(s)")
      expect(described_class.cache_size).to eq(cache_size_before + 1)
    end

    it "respects COLORIZE_CACHE_MAX" do
      described_class.clear_cache
      max = described_class::COLORIZE_CACHE_MAX
      (max + 10).times { |i| described_class.colorize_message("INFO", "msg #{i}: 5 file(s)") }
      expect(described_class.cache_size).to be <= max
    end
  end

  describe ".clear_cache" do
    it "clears all cached entries" do
      described_class.colorize_message("INFO", "something: 3 file(s)")
      expect(described_class.cache_size).to be >= 1
      described_class.clear_cache
      expect(described_class.cache_size).to eq(0)
    end
  end
end
