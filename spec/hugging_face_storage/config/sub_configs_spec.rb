# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::HttpConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.base_url).to eq("https://huggingface.co") }
    it { expect(config.idle_timeout).to eq(60) }
    it { expect(config.open_timeout).to eq(30) }
    it { expect(config.read_timeout).to eq(300) }
    it { expect(config.write_timeout).to eq(30) }
    it { expect(config.stream_chunk_size).to eq(65_536) }
    it { expect(config.debug_mode).to be false }

    it "returns a new instance per call" do
      expect(described_class.default).not_to be(described_class.default)
    end
  end

  describe "#initialize" do
    it "accepts custom values" do
      cfg = described_class.new(base_url: "https://custom.example.com", idle_timeout: 120)
      expect(cfg.base_url).to eq("https://custom.example.com")
      expect(cfg.idle_timeout).to eq(120)
    end

    %i[idle_timeout open_timeout read_timeout write_timeout stream_chunk_size].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it "accepts debug_mode: true without validation" do
      cfg = described_class.new(debug_mode: true)
      expect(cfg.debug_mode).to be true
    end
  end
end

RSpec.describe HuggingFaceStorage::RetryConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.max_retries).to eq(3) }
    it { expect(config.retry_delay).to eq(1) }
    it { expect(config.max_retry_delay).to eq(60) }
  end

  describe "#initialize" do
    it "accepts max_retries: 0 (no retries)" do
      expect { described_class.new(max_retries: 0) }.not_to raise_error
    end

    it "raises when max_retries is negative" do
      expect { described_class.new(max_retries: -1) }.to raise_error(ArgumentError, /max_retries/)
    end

    %i[retry_delay max_retry_delay].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end
  end
end

RSpec.describe HuggingFaceStorage::BatchConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.batch_size).to eq(1000) }
    it { expect(config.delete_batch_size).to eq(20) }
    it { expect(config.copy_batch_size).to eq(20) }
    it { expect(config.batch_threshold).to eq(100 * 1024 * 1024) }
    it { expect(config.batch_memory_limit).to eq(200 * 1024 * 1024) }
    it { expect(config.small_size_threshold).to eq(100 * 1024) }
  end

  describe "validation" do
    %i[batch_size delete_batch_size copy_batch_size
       batch_threshold batch_memory_limit small_size_threshold].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end
  end
end

RSpec.describe HuggingFaceStorage::LogConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.body_log_max).to eq(2000) }
    it { expect(config.colorize_cache_max).to eq(200) }
  end

  describe "validation" do
    %i[body_log_max colorize_cache_max].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end
  end
end

RSpec.describe HuggingFaceStorage::CacheConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.metadata_cache_ttl).to eq(60) }
    it { expect(config.xet_token_cache_size).to eq(1000) }
    it { expect(config.token_expiry_buffer).to eq(60) }
  end

  describe "validation" do
    %i[metadata_cache_ttl xet_token_cache_size token_expiry_buffer].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end
  end
end

RSpec.describe HuggingFaceStorage::ParallelConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.parallel_downloads).to eq(4) }
    it { expect(config.parallel_verify).to eq(8) }
    it { expect(config.stream_threshold).to eq(10 * 1024 * 1024) }
  end

  describe "validation" do
    %i[parallel_downloads parallel_verify stream_threshold].each do |field|
      it "raises when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end
  end
end

RSpec.describe HuggingFaceStorage::EditConfig do
  subject(:config) { described_class.default }

  describe ".default" do
    it { expect(config.max_edit_file_size).to eq(50 * 1024 * 1024) }
  end

  describe "#initialize" do
    it "accepts nil max_edit_file_size (disables guard)" do
      cfg = described_class.new(max_edit_file_size: nil)
      expect(cfg.max_edit_file_size).to be_nil
    end

    it "raises when max_edit_file_size is zero" do
      expect { described_class.new(max_edit_file_size: 0) }.to raise_error(ArgumentError, /max_edit_file_size/)
    end

    it "raises when max_edit_file_size is negative" do
      expect { described_class.new(max_edit_file_size: -1) }.to raise_error(ArgumentError, /max_edit_file_size/)
    end
  end
end
