# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage do
  it "defines FIELD_MAP as a Hash" do
    expect(described_class::FIELD_MAP).to be_a(Hash)
  end

  it "maps base_url to :http" do
    expect(described_class::FIELD_MAP[:base_url]).to eq(:http)
  end

  it "maps idle_timeout to :http" do
    expect(described_class::FIELD_MAP[:idle_timeout]).to eq(:http)
  end

  it "maps max_retries to :retry_config" do
    expect(described_class::FIELD_MAP[:max_retries]).to eq(:retry_config)
  end

  it "maps batch_size to :batch" do
    expect(described_class::FIELD_MAP[:batch_size]).to eq(:batch)
  end

  it "maps body_log_max to :log" do
    expect(described_class::FIELD_MAP[:body_log_max]).to eq(:log)
  end

  it "maps metadata_cache_ttl to :cache" do
    expect(described_class::FIELD_MAP[:metadata_cache_ttl]).to eq(:cache)
  end

  it "maps parallel_downloads to :parallel" do
    expect(described_class::FIELD_MAP[:parallel_downloads]).to eq(:parallel)
  end

  it "maps max_edit_file_size to :edit" do
    expect(described_class::FIELD_MAP[:max_edit_file_size]).to eq(:edit)
  end

  it "is frozen" do
    expect(described_class::FIELD_MAP).to be_frozen
  end
end
