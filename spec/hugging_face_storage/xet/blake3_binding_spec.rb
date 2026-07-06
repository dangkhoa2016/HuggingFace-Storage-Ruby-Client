# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Blake3Binding do
  describe "constants" do
    it "has 32-byte keys" do
      expect(described_class::DATA_KEY.bytesize).to eq(32)
      expect(described_class::NODE_KEY.bytesize).to eq(32)
      expect(described_class::VERIFICATION_KEY.bytesize).to eq(32)
      expect(described_class::ZERO_KEY.bytesize).to eq(32)
    end

    it "has correct buffer sizes" do
      expect(described_class::HASHER_SIZE).to eq(2048)
      expect(described_class::OUT_LEN).to eq(32)
    end

    it "has a thread storage key" do
      expect(described_class::THREAD_STORAGE_KEY).to be_a(Symbol)
    end
  end

  describe ".find_blake3_so" do
    around do |example|
      old = described_class.instance_variable_get(:@blake3_so_path)
      described_class.instance_variable_set(:@blake3_so_path, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@blake3_so_path, old)
    end

    it "falls back to Gem::Specification" do
      allow(Gem).to receive(:find_files).with("digest/blake3/blake3.so").and_return([])
      spec = instance_double(Gem::Specification, gem_dir: "/tmp/gem")
      allow(Gem::Specification).to receive(:find_by_name).with("digest-blake3").and_return(spec)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/tmp/gem/lib/digest/blake3/blake3.so").and_return(true)

      path = described_class.find_blake3_so
      expect(path).to eq("/tmp/gem/lib/digest/blake3/blake3.so")
    end
  end

  describe ".native_available?" do
    it "returns false when C extension is absent" do
      described_class.instance_variable_set(:@native_available, nil)
      allow(described_class).to receive(:require).with("hugging_face_storage/gearhash").and_raise(LoadError)
      expect(described_class.native_available?).to be false
    end
  end

  describe "included in XetHasher" do
    it "exposes constants via XetHasher" do
      expect(HuggingFaceStorage::XetHasher::DATA_KEY).to eq(described_class::DATA_KEY)
      expect(HuggingFaceStorage::XetHasher::HASHER_SIZE).to eq(described_class::HASHER_SIZE)
      expect(HuggingFaceStorage::XetHasher::OUT_LEN).to eq(described_class::OUT_LEN)
    end

    it "exposes class methods via XetHasher" do
      expect(HuggingFaceStorage::XetHasher).to respond_to(:find_blake3_so)
      expect(HuggingFaceStorage::XetHasher).to respond_to(:native_available?)
      expect(HuggingFaceStorage::XetHasher).to respond_to(:_load_native)
    end

    it "provides instance methods on XetHasher" do
      hasher = HuggingFaceStorage::XetHasher.new
      expect(hasher).to respond_to(:blake3_keyed)
      expect(hasher).to respond_to(:blake3_keyed_with_buffers)
      expect(hasher).to respond_to(:init_blake3_lib)
    end
  end

  describe HuggingFaceStorage::Blake3Buffers do
    it "allocates native memory" do
      bufs = HuggingFaceStorage::Blake3Buffers.new
      expect(bufs.hasher_buf).to be_a(Fiddle::Pointer)
      expect(bufs.hasher_buf.size).to eq(HuggingFaceStorage::Blake3Binding::HASHER_SIZE)
      expect(bufs.out_buf).to be_a(Fiddle::Pointer)
      expect(bufs.out_buf.size).to eq(HuggingFaceStorage::Blake3Binding::OUT_LEN)
    end

    it "frees native memory" do
      bufs = HuggingFaceStorage::Blake3Buffers.new
      expect { bufs.free }.not_to raise_error
    end
  end
end
