# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::LfsGuard do
  subject(:guard) { described_class.new("model:org/repo") }

  describe "#check" do
    it "returns nil when there are no offenders" do
      expect(guard.check([])).to be_nil
    end

    it "raises Error when offenders exist" do
      offenders = [{ path: "big.bin", size: 1_000_000 }]
      expect { guard.check(offenders) }
        .to raise_error(HuggingFaceStorage::Error, /big\.bin/)
    end

    it "includes source label in error message" do
      offenders = [{ path: "f.bin", size: 100 }]
      expect { guard.check(offenders) }
        .to raise_error(HuggingFaceStorage::Error, /model:org\/repo/)
    end

    it "truncates long list of offenders" do
      offenders = (1..10).map { |i| { path: "f#{i}.bin", size: i * 100 } }
      expect { guard.check(offenders) }
        .to raise_error(HuggingFaceStorage::Error, /\(and 5 more\)/)
    end

    it "does not add 'and N more' suffix when under limit" do
      offenders = (1..3).map { |i| { path: "f#{i}.bin", size: i * 100 } }
      expect { guard.check(offenders) }
        .to raise_error(HuggingFaceStorage::Error) { |e| expect(e.message).not_to include("more") }
    end
  end
end
