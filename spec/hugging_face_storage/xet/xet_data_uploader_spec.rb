# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::XetDataUploader do
  subject(:uploader) do
    described_class.new(
      hasher: hasher,
      token_manager: token_manager,
      api_client: api_client,
      endpoint: TestHelpers::CAS_URL,
      config: config,
      logger: logger
    )
  end

  let(:hasher) { instance_double(HuggingFaceStorage::XetHasher) }
  let(:serializer) { instance_double(HuggingFaceStorage::XetSerializer) }
  let(:token_manager) { instance_double(HuggingFaceStorage::XetTokenManager) }
  let(:api_client) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:config) { instance_double(HuggingFaceStorage::Configuration) }
  let(:logger) { instance_double(HuggingFaceStorage::HFLogger) }

  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:data) { "hello world" }
  let(:remote_path) { "notes/hello.txt" }

  let(:xorb_hash) { ("\x02" * 32).b }
  let(:file_hash) { ("\x03" * 32).b }

  before do
    allow(HuggingFaceStorage::XetSerializer).to receive(:new).and_return(serializer)
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(token_manager).to receive(:fetch_write_token).with(bucket_id).and_return(
      endpoint: TestHelpers::CAS_URL, token: "xet_write_token_abc", expiration: 9_999_999_999
    )
    allow(hasher).to receive(:cdc_and_hash_native) do |d|
      ranges = [[0, d.bytesize]]
      hashes = ("\x01" * 32).b
      [ranges, hashes]
    end
    allow(hasher).to receive(:batch_blake3_keyed).and_return([("\x01" * 32).b])
    allow(hasher).to receive(:compute_xorb_hash).and_return(xorb_hash)
    allow(hasher).to receive(:compute_file_hash).and_return(file_hash)
    allow(hasher).to receive(:compute_verification_hash).and_return(("\x04" * 32).b)
    allow(serializer).to receive(:serialize_xorb).and_return("xorb_serialized")
    allow(serializer).to receive(:serialize_xorb_from_ranges).and_return("xorb_serialized")
    allow(serializer).to receive(:build_shard).and_return("shard_data")
    allow(api_client).to receive(:batch)
  end

  # ── Constructor ──

  describe "#initialize" do
    it "creates an instance with all required dependencies" do
      expect { uploader }.not_to raise_error
    end

    it "does not create http_pool when transport is provided" do
      transport = double("transport", http_pool: nil, retryable: nil)
      expect(HuggingFaceStorage::HttpPool).not_to receive(:new)
      expect(HuggingFaceStorage::Retryable).not_to receive(:new)
      described_class.new(
        hasher: hasher, token_manager: token_manager,
        api_client: api_client, endpoint: TestHelpers::CAS_URL, config: config,
        logger: logger, transport: transport
      )
    end
  end

  # ── Upload ──

  describe "#upload" do
    let(:pipeline) { uploader.instance_variable_get(:@single_pipeline) }

    before do
      allow(pipeline).to receive(:with_token_retry).and_yield("xet_write_token_abc")
      allow(pipeline).to receive(:upload_xorb)
      allow(pipeline).to receive(:upload_shard)
    end

    it "returns hash with xet_hash and size" do
      result = uploader.upload(bucket_id, data, remote_path)

      expect(result).to eq({ xet_hash: file_hash.unpack1("H*"), size: data.bytesize })
    end

    it "fetches write token" do
      uploader.upload(bucket_id, data, remote_path)

      expect(token_manager).to have_received(:fetch_write_token).with(bucket_id)
    end

    it "calls upload_xorb with serialized data" do
      uploader.upload(bucket_id, data, remote_path)

      expect(pipeline).to have_received(:upload_xorb)
        .with(TestHelpers::CAS_URL, "xet_write_token_abc", xorb_hash, "xorb_serialized", cancel_token: nil)
    end

    it "calls upload_shard with shard data" do
      uploader.upload(bucket_id, data, remote_path)

      expect(pipeline).to have_received(:upload_shard)
        .with(TestHelpers::CAS_URL, "xet_write_token_abc", "shard_data", cancel_token: nil)
    end

    it "registers the file via api.batch" do
      uploader.upload(bucket_id, data, remote_path)

      file_hash_hex = file_hash.unpack1("H*")
      expect(api_client).to have_received(:batch).with(
        bucket_id, [hash_including(type: "addFile", path: remote_path, xetHash: file_hash_hex)],
        cancel_token: nil
      )
    end

    it "calls on_progress callback" do
      callback = double("callback")
      expect(callback).to receive(:call).with(remote_path, data.bytesize, data.bytesize)

      uploader.upload(bucket_id, data, remote_path, on_progress: callback)
    end

    it "logs debug messages" do
      expect(logger).to receive(:debug).at_least(:once)

      uploader.upload(bucket_id, data, remote_path)
    end

    context "with cancel_token" do
      it "raises CancelledError when token is pre-cancelled" do
        token = HuggingFaceStorage::CancelToken.new
        token.cancel!

        expect do
          uploader.upload(bucket_id, data, remote_path, cancel_token: token)
        end.to raise_error(HuggingFaceStorage::CancelledError)
      end
    end

    context "when error occurs" do
      it "propagates error from hasher#cdc_and_hash_native" do
        allow(hasher).to receive(:cdc_and_hash_native).and_raise(StandardError, "chunking failed")

        expect do
          uploader.upload(bucket_id, data, remote_path)
        end.to raise_error(StandardError, "chunking failed")
      end

      it "propagates error from serializer#serialize_xorb_from_ranges" do
        allow(serializer).to receive(:serialize_xorb_from_ranges).and_raise(StandardError, "serialization failed")

        expect do
          uploader.upload(bucket_id, data, remote_path)
        end.to raise_error(StandardError, "serialization failed")
      end
    end
  end

  # ── cdc_and_hash (integrated SHA-256) ──

  describe "#cdc_and_hash (integrated SHA-256)" do
    before do
      allow(hasher).to receive(:cdc_and_hash_native) do |d|
        ranges = [[0, d.bytesize]]
        hashes = ranges.map { |s, e| Digest::SHA256.digest(d.byteslice(s, e - s)) }.join
        [ranges, hashes]
      end
    end

    it "returns SHA-256 as last element for raw string data" do
      result = uploader.send(:cdc_and_hash, data)
      expect(result.size).to eq(5)

      expected_sha256 = Digest::SHA256.digest(data)
      expect(result[4]).to eq(expected_sha256)
    end

    it "returns correct SHA-256 for hash entry with data" do
      entry = { data: "file content here".b, remote_path: "test.txt", size: 17 }
      result = uploader.send(:cdc_and_hash, entry)
      expect(result.size).to eq(5)

      expected_sha256 = Digest::SHA256.digest("file content here".b)
      expect(result[4]).to eq(expected_sha256)
    end

    it "returns correct SHA-256 for hash entry with local_path" do
      require "tempfile"
      tmp = Tempfile.new("test_sha256")
      tmp.binmode
      tmp.write("file from disk content")
      tmp.close

      entry = { local_path: tmp.path, remote_path: "test.txt", size: 22 }
      result = uploader.send(:cdc_and_hash, entry)
      expect(result.size).to eq(5)

      expected_sha256 = Digest::SHA256.digest("file from disk content".b)
      expect(result[4]).to eq(expected_sha256)
    ensure
      tmp&.unlink
    end
  end

  describe "#cdc_and_hash encoding optimization" do
    it "avoids unnecessary copy when data is already ASCII-8BIT" do
      binary_data = "hello world".b
      original_object_id = binary_data.object_id

      uploader_with_real = described_class.new(
        hasher: HuggingFaceStorage::XetHasher.new,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, binary_data)
      returned_data = result[1]

      expect(returned_data.encoding).to eq(Encoding::ASCII_8BIT)
      expect(returned_data.object_id).to eq(original_object_id)
    end

    it "converts UTF-8 data to ASCII-8BIT" do
      utf8_data = "hello world"
      expect(utf8_data.encoding).to eq(Encoding::UTF_8)

      uploader_with_real = described_class.new(
        hasher: HuggingFaceStorage::XetHasher.new,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, utf8_data)
      returned_data = result[1]

      expect(returned_data.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  describe "#cdc_and_hash native integration" do
    let(:real_hasher) { HuggingFaceStorage::XetHasher.new }

    it "produces identical results to sequential path" do
      data = Random.new(42).bytes(2 * 1024 * 1024).b # 2MB

      # Sequential reference
      chunk_ranges_ref = real_hasher.cdc_chunk(data)
      key = HuggingFaceStorage::XetHasher::DATA_KEY
      chunk_hashes_ref = chunk_ranges_ref.map { |s, e| real_hasher.blake3_keyed(key, data.byteslice(s, e - s)) }
      sha256_ref = Digest::SHA256.digest(data)

      # Native path
      uploader_with_real = described_class.new(
        hasher: real_hasher,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, data)
      chunk_ranges, _source, chunk_hashes, chunk_lengths, sha256 = result

      expect(chunk_ranges).to eq(chunk_ranges_ref)
      expect(chunk_hashes).to eq(chunk_hashes_ref)
      expect(sha256).to eq(sha256_ref)
      expect(chunk_lengths).to eq(chunk_ranges.map { |s, e| e - s })
    end

    it "handles small data below parallel threshold" do
      data = ("x" * 512).b # 512 bytes

      uploader_with_real = described_class.new(
        hasher: real_hasher,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, data)
      chunk_ranges, _source, chunk_hashes, chunk_lengths, sha256 = result

      expect(sha256).to eq(Digest::SHA256.digest(data))
      expect(chunk_hashes.first.bytesize).to eq(32)
      expect(chunk_lengths.first).to eq(data.bytesize)
    end
  end

  describe "#cdc_and_hash parallelism" do
    let(:real_hasher) { HuggingFaceStorage::XetHasher.new }

    it "has parallel threshold at 256KB" do
      expect(HuggingFaceStorage::XetDataUploader::PARALLEL_CDC_SHA256_THRESHOLD).to eq(256 * 1024)
    end

    it "produces identical results to sequential path for large data" do
      data = Random.new(42).bytes(2 * 1024 * 1024).b  # 2MB

      # Sequential: SHA-256 then CDC
      sha256_seq = Digest::SHA256.digest(data)
      chunk_ranges_seq = real_hasher.cdc_chunk(data)

      # Parallel: both at once (via the uploader's cdc_and_hash)
      uploader_with_real = described_class.new(
        hasher: real_hasher,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, data)
      chunk_ranges_par, _source, _hashes, _lengths, sha256_par = result

      expect(sha256_par).to eq(sha256_seq)
      expect(chunk_ranges_par).to eq(chunk_ranges_seq)
    end

    it "uses sequential path for small data below threshold" do
      data = ("x" * 128).b  # 128 bytes < 256KB threshold

      uploader_with_real = described_class.new(
        hasher: real_hasher,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, data)
      _chunk_ranges, _source, _hashes, _lengths, sha256 = result

      expect(sha256).to eq(Digest::SHA256.digest(data))
    end

    it "uses parallel path for data above new 256KB threshold" do
      data = Random.new(42).bytes(300 * 1024).b  # 300KB > 256KB threshold

      uploader_with_real = described_class.new(
        hasher: real_hasher,
        token_manager: token_manager,
        api_client: api_client,
        endpoint: TestHelpers::CAS_URL,
        config: config,
        logger: logger
      )
      result = uploader_with_real.send(:cdc_and_hash, data)
      chunk_ranges, _source, _hashes, _lengths, sha256 = result

      expect(sha256).to eq(Digest::SHA256.digest(data))
      expect(chunk_ranges).to eq(real_hasher.cdc_chunk(data))
    end
  end
end
