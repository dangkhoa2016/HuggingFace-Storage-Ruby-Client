# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ConfigValidation do
  let(:dummy_class) do
    Class.new do
      include HuggingFaceStorage::ConfigValidation

      public :validate_positive, :validate_non_negative
    end
  end

  subject(:dummy) { dummy_class.new }

  describe "#validate_positive" do
    it "passes with a positive integer" do
      expect(dummy.validate_positive(42, :count)).to eq(42)
    end

    it "passes with a positive float" do
      expect(dummy.validate_positive(3.14, :ratio)).to eq(3.14)
    end

    it "raises with zero" do
      expect { dummy.validate_positive(0, :count) }
        .to raise_error(ArgumentError, /count/)
    end

    it "raises with a negative integer" do
      expect { dummy.validate_positive(-1, :count) }
        .to raise_error(ArgumentError, /count/)
    end

    it "raises with nil" do
      expect { dummy.validate_positive(nil, :count) }
        .to raise_error(ArgumentError, /count/)
    end

    it "raises with a string" do
      expect { dummy.validate_positive("abc", :count) }
        .to raise_error(ArgumentError, /count/)
    end
  end

  describe "#validate_non_negative" do
    it "passes with zero" do
      expect(dummy.validate_non_negative(0, :max_retries)).to eq(0)
    end

    it "passes with a positive integer" do
      expect(dummy.validate_non_negative(5, :max_retries)).to eq(5)
    end

    it "passes with a positive float" do
      expect(dummy.validate_non_negative(1.5, :delay)).to eq(1.5)
    end

    it "raises with a negative integer" do
      expect { dummy.validate_non_negative(-1, :max_retries) }
        .to raise_error(ArgumentError, /max_retries/)
    end

    it "raises with a negative float" do
      expect { dummy.validate_non_negative(-0.1, :delay) }
        .to raise_error(ArgumentError, /delay/)
    end

    it "raises with nil" do
      expect { dummy.validate_non_negative(nil, :max_retries) }
        .to raise_error(ArgumentError, /max_retries/)
    end

    it "raises with a string" do
      expect { dummy.validate_non_negative("abc", :count) }
        .to raise_error(ArgumentError, /count/)
    end
  end
end
