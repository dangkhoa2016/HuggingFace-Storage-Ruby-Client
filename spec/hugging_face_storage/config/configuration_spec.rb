# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::Configuration do
  subject(:config) { described_class.new }

  describe "default values" do
    it { expect(config.batch_size).to eq(1000) }
    it { expect(config.delete_batch_size).to eq(20) }
    it { expect(config.copy_batch_size).to eq(20) }
    it { expect(config.batch_threshold).to eq(100 * 1024 * 1024) }
    it { expect(config.batch_memory_limit).to eq(200 * 1024 * 1024) }
    it { expect(config.small_size_threshold).to eq(100 * 1024) }
    it { expect(config.max_retries).to eq(3) }
    it { expect(config.retry_delay).to eq(1) }
    it { expect(config.max_retry_delay).to eq(60) }
    it { expect(config.idle_timeout).to eq(60) }
    it { expect(config.open_timeout).to eq(30) }
    it { expect(config.read_timeout).to eq(300) }
    it { expect(config.write_timeout).to eq(30) }
    it { expect(config.stream_chunk_size).to eq(65_536) }
    it { expect(config.token_expiry_buffer).to eq(60) }
    it { expect(config.stream_threshold).to eq(10 * 1024 * 1024) }
    it { expect(config.parallel_downloads).to eq(4) }
    it { expect(config.parallel_verify).to eq(8) }
    it { expect(config.max_edit_file_size).to eq(50 * 1024 * 1024) }
    it { expect(config.body_log_max).to eq(2000) }
    it { expect(config.colorize_cache_max).to eq(200) }
    it { expect(config.xet_token_cache_size).to eq(1000) }
    it { expect(config.base_url).to eq("https://huggingface.co") }
    it { expect(config.metadata_cache_ttl).to eq(60) }
  end

  describe "validation" do
    %i[
      batch_size delete_batch_size copy_batch_size
      batch_threshold batch_memory_limit small_size_threshold
      retry_delay max_retry_delay
      idle_timeout open_timeout read_timeout write_timeout
      stream_chunk_size token_expiry_buffer stream_threshold
      parallel_downloads parallel_verify
      body_log_max colorize_cache_max xet_token_cache_size metadata_cache_ttl
    ].each do |field|
      it "raises ArgumentError when #{field} is zero" do
        expect { described_class.new(field => 0) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises ArgumentError when #{field} is negative" do
        expect { described_class.new(field => -1) }.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it "raises ArgumentError when max_retries is negative" do
      expect { described_class.new(max_retries: -1) }.to raise_error(ArgumentError, /max_retries/)
    end

    it "accepts max_retries = 0 (no retries)" do
      expect { described_class.new(max_retries: 0) }.not_to raise_error
    end

    it "accepts max_edit_file_size = nil (disables guard)" do
      expect { described_class.new(max_edit_file_size: nil) }.not_to raise_error
    end

    it "raises ArgumentError when batch_size is non-numeric" do
      expect { described_class.new(batch_size: "abc") }.to raise_error(ArgumentError, /batch_size/)
    end

    it "accepts float values for retry_delay" do
      expect { described_class.new(retry_delay: 0.001) }.not_to raise_error
    end
  end

  describe "immutability" do
    it "creates modified copies via with" do
      modified = config.with(retry_delay: 5)
      expect(config.retry_delay).to eq(1)
      expect(modified.retry_delay).to eq(5)
    end
  end

  describe ".default" do
    it "returns a fresh instance per call so clients do not share mutable config" do
      expect(described_class.default).not_to be(described_class.default)
    end

    it "returns an instance with the standard default values" do
      expect(described_class.default.batch_size).to eq(1000)
    end
  end

  describe "#with" do
    it "creates an independent copy" do
      original = described_class.new
      copy = original.with(max_retries: 99)
      expect(original.max_retries).to eq(3)
      expect(copy.max_retries).to eq(99)
    end

    it "copies all settings" do
      original = described_class.new(batch_size: 500)
      copy = original.with
      expect(copy.batch_size).to eq(500)
    end
  end

  describe "sub-config access" do
    it "provides http sub-config" do
      expect(config.http).to be_a(described_class::HttpConfig)
    end

    it "provides retry sub-config via #retry" do
      expect(config.retry).to be_a(described_class::RetryConfig)
    end

    it "provides retry sub-config via #retry_config" do
      expect(config.retry_config).to be_a(described_class::RetryConfig)
    end

    it "provides batch sub-config" do
      expect(config.batch).to be_a(described_class::BatchConfig)
    end

    it "provides log sub-config" do
      expect(config.log).to be_a(described_class::LogConfig)
    end

    it "provides cache sub-config" do
      expect(config.cache).to be_a(described_class::CacheConfig)
    end

    it "provides parallel sub-config" do
      expect(config.parallel).to be_a(described_class::ParallelConfig)
    end

    it "provides edit sub-config" do
      expect(config.edit).to be_a(described_class::EditConfig)
    end

    it "allows construction with sub-config objects" do
      custom_http = described_class::HttpConfig.new(base_url: "https://custom.example.com")
      cfg = described_class.new(http: custom_http)
      expect(cfg.http).to be(custom_http)
      expect(cfg.base_url).to eq("https://custom.example.com")
    end
  end

  describe "backward-compatible delegates match sub-configs" do
    it { expect(config.base_url).to eq(config.http.base_url) }
    it { expect(config.idle_timeout).to eq(config.http.idle_timeout) }
    it { expect(config.max_retries).to eq(config.retry.max_retries) }
    it { expect(config.retry_delay).to eq(config.retry.retry_delay) }
    it { expect(config.batch_size).to eq(config.batch.batch_size) }
    it { expect(config.delete_batch_size).to eq(config.batch.delete_batch_size) }
    it { expect(config.body_log_max).to eq(config.log.body_log_max) }
    it { expect(config.metadata_cache_ttl).to eq(config.cache.metadata_cache_ttl) }
    it { expect(config.parallel_downloads).to eq(config.parallel.parallel_downloads) }
    it { expect(config.max_edit_file_size).to eq(config.edit.max_edit_file_size) }
  end

  describe "default sub-configs are valid" do
    it "has valid sub-configs from .default" do
      default = described_class.default
      expect(default.http).to be_a(described_class::HttpConfig)
      expect(default.retry).to be_a(described_class::RetryConfig)
      expect(default.batch).to be_a(described_class::BatchConfig)
      expect(default.log).to be_a(described_class::LogConfig)
      expect(default.cache).to be_a(described_class::CacheConfig)
      expect(default.parallel).to be_a(described_class::ParallelConfig)
      expect(default.edit).to be_a(described_class::EditConfig)
    end
  end
end
