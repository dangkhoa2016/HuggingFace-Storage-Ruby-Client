# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Color do
  it "defines RESET" do
    expect(described_class::RESET).to eq("\e[0m")
  end

  it "defines BOLD" do
    expect(described_class::BOLD).to eq("\e[1m")
  end

  it "defines DIM" do
    expect(described_class::DIM).to eq("\e[2m")
  end

  it "defines color constants" do
    expect(described_class::RED).to eq("\e[31m")
    expect(described_class::GREEN).to eq("\e[32m")
    expect(described_class::YELLOW).to eq("\e[33m")
    expect(described_class::BLUE).to eq("\e[34m")
    expect(described_class::MAGENTA).to eq("\e[35m")
    expect(described_class::CYAN).to eq("\e[36m")
    expect(described_class::WHITE).to eq("\e[37m")
  end

  it "defines bright color constants" do
    expect(described_class::BRIGHT_RED).to eq("\e[91m")
    expect(described_class::BRIGHT_GREEN).to eq("\e[92m")
  end

  it "defines BLACK" do
    expect(described_class::BLACK).to eq("\e[30m")
  end

  describe ".strip" do
    it "removes ANSI escape codes" do
      expect(described_class.strip("\e[31mhello\e[0m")).to eq("hello")
    end

    it "returns plain strings unchanged" do
      expect(described_class.strip("hello")).to eq("hello")
    end
  end
end
