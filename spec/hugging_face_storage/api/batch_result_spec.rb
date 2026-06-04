# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::BatchResult do
  subject(:result) { described_class.new }

  describe "empty batch" do
    it "is empty" do
      expect(result).to be_empty
    end

    it "has zero success and failure counts" do
      expect(result.success_count).to eq(0)
      expect(result.failure_count).to eq(0)
    end

    it "is successful (no failures)" do
      expect(result).to be_success
    end

    it "returns empty arrays in to_h" do
      h = result.to_h
      expect(h[:succeeded]).to eq([])
      expect(h[:failed]).to eq([])
    end
  end

  describe "all succeeded" do
    before do
      result.add_success({ type: "addFile", path: "a.txt" })
      result.add_success({ type: "addFile", path: "b.txt" })
    end

    it "reports correct success count" do
      expect(result.success_count).to eq(2)
    end

    it "reports zero failure count" do
      expect(result.failure_count).to eq(0)
    end

    it "is successful" do
      expect(result).to be_success
    end

    it "is not empty" do
      expect(result).not_to be_empty
    end

    it "does not raise on raise_if_any!" do
      expect { result.raise_if_any! }.not_to raise_error
    end
  end

  describe "mixed succeeded and failed" do
    before do
      result.add_success({ type: "addFile", path: "good.txt" })
      result.add_failure("bad.txt", "permission denied")
      result.add_failure("ugly.txt", "not found")
    end

    it "reports correct counts" do
      expect(result.success_count).to eq(1)
      expect(result.failure_count).to eq(2)
    end

    it "is not successful" do
      expect(result).not_to be_success
    end

    it "is not empty" do
      expect(result).not_to be_empty
    end

    it "raises PartialFailureError on raise_if_any!" do
      expect { result.raise_if_any! }
        .to raise_error(HuggingFaceStorage::PartialFailureError) do |e|
          expect(e.message).to include("2 operation(s) failed")
          expect(e.result).to eq(result)
        end
    end
  end

  describe "#to_h" do
    it "returns succeeded and failed as separate arrays" do
      result.add_success({ type: "addFile", path: "a.txt" })
      result.add_failure("b.txt", "error")
      h = result.to_h
      expect(h).to be_a(Hash)
      expect(h.keys).to contain_exactly(:succeeded, :failed)
      expect(h[:succeeded]).to eq([{ type: "addFile", path: "a.txt" }])
      expect(h[:failed]).to eq([{ path: "b.txt", error: "error" }])
    end

    it "returns duplicated arrays (not internal references)" do
      result.add_success({ type: "addFile", path: "a.txt" })
      h = result.to_h
      h[:succeeded] << :tamper
      expect(result.succeeded).to eq([{ type: "addFile", path: "a.txt" }])
    end
  end

  describe "#add_success chaining" do
    it "returns self for chaining" do
      r = result.add_success({ type: "addFile", path: "a.txt" })
      expect(r).to eq(result)
    end

    it "allows chained calls" do
      result.add_success({ type: "addFile", path: "a.txt" })
             .add_success({ type: "addFile", path: "b.txt" })
      expect(result.success_count).to eq(2)
    end
  end

  describe "#add_failure chaining" do
    it "returns self for chaining" do
      r = result.add_failure("a.txt", "error")
      expect(r).to eq(result)
    end

    it "allows chained calls" do
      result.add_failure("a.txt", "err1")
             .add_failure("b.txt", "err2")
      expect(result.failure_count).to eq(2)
    end
  end

  describe "#merge!" do
    it "merges another result" do
      other = described_class.new
      other.add_success({ type: "addFile", path: "b.txt" })
      other.add_failure("c.txt", "error")

      result.add_success({ type: "addFile", path: "a.txt" })
      result.merge!(other)

      expect(result.success_count).to eq(2)
      expect(result.failure_count).to eq(1)
      expect(result.succeeded).to include({ type: "addFile", path: "a.txt" })
      expect(result.succeeded).to include({ type: "addFile", path: "b.txt" })
    end

    it "returns self" do
      other = described_class.new
      expect(result.merge!(other)).to eq(result)
    end

    it "handles merging an empty result" do
      result.add_success({ type: "addFile", path: "a.txt" })
      result.merge!(described_class.new)
      expect(result.success_count).to eq(1)
    end
  end

  describe "#succeeded" do
    it "returns the array of succeeded entries" do
      result.add_success({ type: "addFile", path: "a.txt" })
      expect(result.succeeded).to eq([{ type: "addFile", path: "a.txt" }])
    end
  end

  describe "#failed" do
    it "returns the array of failed entries" do
      result.add_failure("a.txt", "error")
      expect(result.failed).to eq([{ path: "a.txt", error: "error" }])
    end
  end
end
