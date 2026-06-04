# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Utils do
  describe ".hash_to_hex" do
    it "converts 32 bytes to hex" do
      bytes = [0x0011223344556677, 0x8899AABBCCDDEEFF, 0x0123456789ABCDEF, 0xFEDCBA9876543210].pack("Q<4")
      result = described_class.hash_to_hex(bytes)
      expect(result).to match(/\A\h{64}\z/)
      expect(result.length).to eq(64)
    end

    it "raises for non-32-byte input" do
      expect { described_class.hash_to_hex("short") }.to raise_error(ArgumentError, /requires 32 bytes/)
    end
  end

  describe ".human_size" do
    it 'returns "0 B" for zero' do
      expect(described_class.human_size(0)).to eq("0 B")
    end

    it "returns bytes for < 1024" do
      expect(described_class.human_size(500)).to eq("500 B")
    end

    it "returns KB for 1024..1_048_575" do
      expect(described_class.human_size(2048)).to eq("2.0 KB")
    end

    it "returns MB for 1_048_576..1_073_741_823" do
      expect(described_class.human_size(2_097_152)).to eq("2.0 MB")
    end

    it "returns GB for 1_073_741_824..1_099_511_627_775" do
      expect(described_class.human_size(2_147_483_648)).to eq("2.0 GB")
    end

    it "returns TB for >= 1_099_511_627_776" do
      expect(described_class.human_size(2_199_023_255_552)).to eq("2.0 TB")
    end
  end
end
