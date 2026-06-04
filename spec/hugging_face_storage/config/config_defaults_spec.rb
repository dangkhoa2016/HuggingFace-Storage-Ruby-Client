# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::ConfigDefaults do
  let(:dummy_class) do
    Class.new do
      include HuggingFaceStorage::ConfigDefaults

      def initialize
        @foo = 1
        @bar = "two"
        @baz = :three
      end
    end
  end

  subject(:instance) { dummy_class.new }

  describe "#to_h" do
    it "converts instance variables to a hash with symbol keys" do
      expect(instance.to_h).to eq({ foo: 1, bar: "two", baz: :three })
    end

    it "excludes private internals like @config" do
      klass = Class.new do
        include HuggingFaceStorage::ConfigDefaults

        def initialize
          @name = "test"
          @config = { key: "val" }
        end
      end
      expect(klass.new.to_h).to eq({ name: "test", config: { key: "val" } })
    end

    it "returns empty hash when there are no instance variables" do
      empty = Class.new do
        include HuggingFaceStorage::ConfigDefaults
      end.new
      expect(empty.to_h).to eq({})
    end
  end
end
