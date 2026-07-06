# frozen_string_literal: true

require "spec_helper"
require "benchmark"

RSpec.describe "Benchmark: batch upload performance", :benchmark do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive_messages(get_xet_write_token: { endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999 },
batch: HuggingFaceStorage::BatchResult.new)
    end
  end
  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:serializer) { HuggingFaceStorage::XetSerializer.new(hasher) }
  let(:token_manager) { HuggingFaceStorage::XetTokenManager.new(api_client: api, logger: logger) }
  let(:uploader) do
    HuggingFaceStorage::XetUploader.new(
      hasher: hasher, serializer: serializer,
      token_manager: token_manager, api_client: api,
      endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger
    )
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }

  before do
    stub_request(:post, %r{cas\.huggingface\.co/v1/xorbs})
      .to_return(status: 200, body: "")
    stub_request(:post, %r{cas\.huggingface\.co/v1/shards})
      .to_return(status: 200, body: "")
  end

  it "measures batch upload time for 20 small files" do
    entries = (1..20).map do |i|
      { data: Random.bytes(1024), remote_path: "batch/file_#{i}.bin", size: 1024 }
    end

    time = Benchmark.measure do
      uploader.upload_batch(bucket_id, entries)
    end

    expect(time.real).to be < 30.0
  end

  it "measures batch upload time for 5 medium files" do
    entries = (1..5).map do |i|
      { data: Random.bytes(10_240), remote_path: "batch/file_#{i}.bin", size: 10_240 }
    end

    time = Benchmark.measure do
      uploader.upload_batch(bucket_id, entries)
    end

    expect(time.real).to be < 30.0
  end
end

RSpec.describe "Benchmark: batch splitting", :benchmark do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:logger) { null_logger }

  it "splits batch correctly for large number of operations" do
    config = HuggingFaceStorage::Configuration.new(batch_size: 500)

    api_client = HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger, config: config)
    allow(api_client).to receive(:post_ndjson).and_return(nil)

    ops = (1..1234).map { |i| { type: "addFile", path: "file_#{i}.txt" } }

    expect(api_client).to receive(:post_ndjson).exactly(3).times.and_return(nil)

    api_client.batch(TestHelpers::BUCKET_ID, ops)
  end
end

RSpec.describe "Benchmark: Xet hashing and chunking", :benchmark do
  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:key) { HuggingFaceStorage::XetHasher::DATA_KEY }

  it "measures BLAKE3 hashing throughput for various sizes" do
    sizes = { "1KB" => 1024, "10KB" => 10_240, "100KB" => 102_400 }

    sizes.each_value do |size|
      data = Random.bytes(size)
      time = Benchmark.measure do
        50.times { hasher.blake3_keyed(key, data) }
      end
      (50.0 / time.real).round(0)

      expect(time.real).to be < 10.0
    end
  end

  it "measures CDC chunking throughput" do
    sizes = { "10KB" => 10_240, "100KB" => 102_400 }

    sizes.each_value do |size|
      data = Random.bytes(size)
      time = Benchmark.measure do
        5.times { hasher.cdc_chunk(data) }
      end

      expect(time.real).to be < 30.0
    end
  end

  it "measures xorb hash tree computation" do
    [10, 50, 200].each do |num_chunks|
      chunk_hashes = num_chunks.times.map { Random.bytes(32) }
      chunk_lengths = num_chunks.times.map { rand(8192..131_072) }
      infos = chunk_hashes.zip(chunk_lengths)

      time = Benchmark.measure do
        10.times { hasher.compute_xorb_hash(infos) }
      end

      expect(time.real).to be < 5.0
    end
  end
end

RSpec.describe "Benchmark: Configuration defaults", :benchmark do
  it "creates Configuration instances quickly" do
    time = Benchmark.measure do
      1000.times { HuggingFaceStorage::Configuration.new }
    end

    expect(time.real).to be < 1.0
  end
end

RSpec.describe "Benchmark: Utils.human_size", :benchmark do
  it "formats sizes quickly" do
    time = Benchmark.measure do
      10_000.times { HuggingFaceStorage::Utils.human_size(rand(0..1_099_511_627_776)) }
    end

    expect(time.real).to be < 1.0
  end
end

RSpec.describe "Benchmark: Paths utilities", :benchmark do
  it "normalizes paths quickly" do
    time = Benchmark.measure do
      10_000.times { HuggingFaceStorage::Paths.normalize("/some/path/with/slashes/") }
    end

    expect(time.real).to be < 1.0
  end

  it "encodes segments quickly" do
    time = Benchmark.measure do
      10_000.times { HuggingFaceStorage::Paths.encode_segments("models/my model/config file.json") }
    end

    expect(time.real).to be < 1.0
  end
end

RSpec.describe "Benchmark: CancelToken operations", :benchmark do
  it "creates and checks cancel tokens quickly" do
    time = Benchmark.measure do
      10_000.times do
        token = HuggingFaceStorage::CancelToken.new
        token.cancelled?
        token.cancel!
        token.cancelled?
      end
    end

    expect(time.real).to be < 2.0
  end
end

RSpec.describe "Benchmark: BatchResult operations", :benchmark do
  it "tracks successes and failures efficiently" do
    time = Benchmark.measure do
      result = HuggingFaceStorage::BatchResult.new
      1000.times { |i| result.add_success({ type: "addFile", path: "file_#{i}.txt" }) }
      100.times { |i| result.add_failure("fail_#{i}.txt", "error") }
      result.success_count
      result.failure_count
      result.success?
    end

    expect(time.real).to be < 1.0
  end
end
