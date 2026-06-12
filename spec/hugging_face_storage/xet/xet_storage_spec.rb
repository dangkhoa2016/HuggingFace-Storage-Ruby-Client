# frozen_string_literal: true

require "spec_helper"

RSpec.describe "XetUploader and XetDownloader (formerly XetStorage)" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_write_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999
      )
      allow(a).to receive(:get_xet_read_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_read_abc", expiration: 9999999999
      )
      allow(a).to receive(:batch)
      allow(a).to receive(:post).and_return([{ "path" => "test.txt", "size" => 100, "xetHash" => "abc123" }])
      allow(a).to receive(:request_with_redirect) do |uri, **kwargs, &block|
        HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger).request_with_redirect(uri, **kwargs, &block)
      end
      allow(a).to receive(:stream_with_redirect) do |uri, **kwargs, &block|
        HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger).stream_with_redirect(uri, **kwargs, &block)
      end
    end
  end

  let(:config) { HuggingFaceStorage::Configuration.new(retry_delay: 0.001) }
  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:serializer) { HuggingFaceStorage::XetSerializer.new(hasher) }
  let(:token_manager) { HuggingFaceStorage::XetTokenManager.new(api_client: api, logger: logger, config: config) }
  let(:uploader) do
    HuggingFaceStorage::XetUploader.new(
      hasher: hasher, serializer: serializer,
      token_manager: token_manager, api_client: api,
      endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger, config: config
    )
  end
  let(:downloader) do
    HuggingFaceStorage::XetDownloader.new(
      api_client: api, token_manager: token_manager,
      endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger, config: config
    )
  end

  # ── Upload Flow ──

  describe "XetUploader#upload_bytes_to_path" do
    it "performs full upload flow: chunk, hash, xorb, shard, batch" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      uploader.upload_bytes_to_path(TestHelpers::BUCKET_ID, "hello world", "notes/hello.txt")

      expect(api).to have_received(:get_xet_write_token).with(TestHelpers::BUCKET_ID)
      expect(api).to have_received(:batch).with(TestHelpers::BUCKET_ID, array_including(
        hash_including(type: "addFile", path: "notes/hello.txt")
      ), hash_including(cancel_token: nil))
    end
  end

  describe "XetUploader#upload_file_to_path" do
    it "reads file and uploads" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.txt")
        File.write(path, "file content for upload")

        result = uploader.upload_file_to_path(TestHelpers::BUCKET_ID, path, "remote/test.txt")
        expect(result[:xet_hash]).to be_a(String)
        expect(result[:size]).to eq("file content for upload".bytesize)
      end
    end

    it "streams large files above BATCH_THRESHOLD" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "large.bin")
        File.write(path, "x" * 1000)

        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(path).and_return(101 * 1024 * 1024 + 1)

        result = uploader.upload_file_to_path(TestHelpers::BUCKET_ID, path, "remote/large.bin")
        expect(result[:xet_hash]).to be_a(String)
        expect(result[:size]).to eq(1000)
      end
    end
  end

  describe "XetUploader#stream_download_and_upload" do
    it "streams download block into upload" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      result = uploader.stream_download_and_upload(TestHelpers::BUCKET_ID, "remote/streamed.bin") do |&write_chunk|
        write_chunk.call("streamed data")
      end

      expect(result[:xet_hash]).to be_a(String)
      expect(result[:size]).to eq("streamed data".bytesize)
    end

    it "triggers CDC splits and xorb flush with large data" do
      stub_const("HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS", 1)
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      result = uploader.stream_download_and_upload(TestHelpers::BUCKET_ID, "remote/large.bin") do |&write_chunk|
        write_chunk.call("a" * 50_000)
      end

      expect(result[:xet_hash]).to be_a(String)
      expect(result[:size]).to eq(50_000)
    end
  end

  describe "XetUploader progress callbacks" do
    it "calls progress callback via small-file path" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "upload.bin")
        File.write(path, "x" * 100_000)

        progress_calls = []
        uploader.upload_file_to_path(TestHelpers::BUCKET_ID, path, "remote/uploaded.bin",
          on_progress: ->(path, pos, total) { progress_calls << [path, pos, total] }
        )

        expect(progress_calls.size).to be >= 1
        expect(progress_calls.last[2]).to eq(100_000)
      end
    end

    it "calls progress callback via streaming path" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      Dir.mktmpdir do |dir|
        custom_config = HuggingFaceStorage::Configuration.new(retry_delay: 0.001, stream_threshold: 1)
        custom_uploader = HuggingFaceStorage::XetUploader.new(
          hasher: hasher, serializer: serializer,
          token_manager: token_manager, api_client: api,
          endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger, config: custom_config
        )
        path = File.join(dir, "upload.bin")
        File.write(path, "x" * 200_000)

        progress_calls = []
        custom_uploader.upload_file_to_path(TestHelpers::BUCKET_ID, path, "remote/uploaded.bin",
          on_progress: ->(path, pos, total) { progress_calls << [path, pos, total] }
        )

        expect(progress_calls.size).to be >= 1
        expect(progress_calls.last[2]).to eq(200_000)
      end
    end
  end

  # ── Batch Upload ──

  describe "XetUploader#upload_batch" do
    it "returns empty array for empty entries" do
      result = uploader.upload_batch(TestHelpers::BUCKET_ID, [])
      expect(result).to eq([])
    end

    it "uploads multiple files in single batch" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      entries = [
        { data: "file one".b, remote_path: "a.txt", size: 8 },
        { data: "file two".b, remote_path: "b.txt", size: 8 }
      ]

      results = uploader.upload_batch(TestHelpers::BUCKET_ID, entries)
      expect(results.size).to eq(2)
      expect(results[0][:path]).to eq("a.txt")
      expect(results[1][:path]).to eq("b.txt")
      expect(api).to have_received(:batch).once
    end

    it "reads entry data from local_path when :data is absent" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      Dir.mktmpdir do |dir|
        path_a = File.join(dir, "a.bin")
        path_b = File.join(dir, "b.bin")
        File.binwrite(path_a, "disk-file-one")
        File.binwrite(path_b, "disk-file-two")

        entries = [
          { local_path: path_a, remote_path: "a.bin", size: File.size(path_a) },
          { local_path: path_b, remote_path: "b.bin", size: File.size(path_b) }
        ]

        results = uploader.upload_batch(TestHelpers::BUCKET_ID, entries)
        expect(results.size).to eq(2)
        expect(results[0][:path]).to eq("a.bin")
        expect(results[1][:path]).to eq("b.bin")
      end
    end

    it "calls on_progress callback" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      progress = []
      entries = [
        { data: "data1".b, remote_path: "p1.txt", size: 5 },
        { data: "data2".b, remote_path: "p2.txt", size: 5 }
      ]

      uploader.upload_batch(TestHelpers::BUCKET_ID, entries, on_progress: lambda { |i, path, size|
        progress << [i, path, size]
      })
      expect(progress.size).to eq(2)
      sorted = progress.sort_by { |p| p[0] }
      expect(sorted[0][1]).to eq("p1.txt")
      expect(sorted[1][1]).to eq("p2.txt")
    end

    it "splits into groups when files exceed BATCH_MEMORY_LIMIT" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      limit = HuggingFaceStorage::Configuration.default.batch_memory_limit
      entries = [
        { data: "a".b, remote_path: "a.txt", size: limit },
        { data: "b".b, remote_path: "b.txt", size: limit }
      ]

      results = uploader.upload_batch(TestHelpers::BUCKET_ID, entries)
      expect(results.size).to eq(2)
      expect(api).to have_received(:batch).twice
    end

    it "flushes xorb when chunk limit is exceeded during batch" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      stub_const("HuggingFaceStorage::XetHasher::XORB_MAX_CHUNKS", 2)

      entries = [
        { data: "a" * 50_000, remote_path: "f1.txt", size: 50_000 },
        { data: "b" * 50_000, remote_path: "f2.txt", size: 50_000 },
        { data: "c" * 50_000, remote_path: "f3.txt", size: 50_000 }
      ]

      results = uploader.upload_batch(TestHelpers::BUCKET_ID, entries)
      expect(results.size).to eq(3)
      expect(api).to have_received(:batch).once
    end
  end

  # ── Download ──

  describe "XetDownloader#download_file" do
    it "downloads file and writes to local path" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/test.txt")
        .to_return(status: 200, body: "downloaded content")

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "output.txt")
        downloader.download_file(TestHelpers::BUCKET_ID, "test.txt", local_path)
        expect(File.read(local_path)).to eq("downloaded content")
      end
    end

    it "follows redirects" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/models/data.bin")
        .to_return(status: 302, headers: { "Location" => "https://cdn.example.com/data.bin" })
      stub_request(:get, "https://cdn.example.com/data.bin")
        .to_return(status: 200, body: "redirected content")

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "data.bin")
        downloader.download_file(TestHelpers::BUCKET_ID, "models/data.bin", local_path)
        expect(File.read(local_path)).to eq("redirected content")
      end
    end

    it "creates parent directories" do
      stub_request(:get, /resolve/)
        .to_return(status: 200, body: "data")

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "sub", "dir", "file.txt")
        downloader.download_file(TestHelpers::BUCKET_ID, "file.txt", local_path)
        expect(File.exist?(local_path)).to be true
      end
    end

    it "falls back to CAS when CDN fails" do
      resolve_url = "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin"
      stub_request(:get, resolve_url)
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 200, body: "cas data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 8, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "data.bin")
        downloader.download_file(TestHelpers::BUCKET_ID, "data.bin", local_path)
        expect(File.read(local_path)).to eq("cas data")
      end
    end

    it "follows redirects in CAS streaming fallback" do
      resolve_url = "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin"
      stub_request(:get, resolve_url)
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 302, headers: { "Location" => "https://cdn.example.com/cas-data.bin" })
      stub_request(:get, "https://cdn.example.com/cas-data.bin")
        .to_return(status: 200, body: "redirected cas data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 17, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "data.bin")
        downloader.download_file(TestHelpers::BUCKET_ID, "data.bin", local_path)
        expect(File.read(local_path)).to eq("redirected cas data")
      end
    end

    it "raises ApiError when CAS streaming fails" do
      resolve_url = "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin"
      stub_request(:get, resolve_url)
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 502, body: "bad gateway")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 8, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "data.bin")
        expect {
          downloader.download_file(TestHelpers::BUCKET_ID, "data.bin", local_path)
        }.to raise_error(HuggingFaceStorage::ApiError, /Reconstruction fetch failed/)
      end
    end

    it "retries CAS streaming on network exception then succeeds" do
      resolve_url = "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin"
      stub_request(:get, resolve_url)
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_raise(Errno::ECONNRESET).then
        .to_return(status: 200, body: "recovered data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 13, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      Dir.mktmpdir do |dir|
        local_path = File.join(dir, "data.bin")
        downloader.download_file(TestHelpers::BUCKET_ID, "data.bin", local_path)
        expect(File.read(local_path)).to eq("recovered data")
      end
    end

    it "retries CAS download on network exception then succeeds" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_raise(Errno::ECONNRESET).then
        .to_return(status: 200, body: "recovered data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 13, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      result = downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      expect(result).to eq("recovered data")
    end
  end

  describe "XetDownloader#download_data" do
    it "follows redirects and returns body" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 302, headers: { "Location" => "https://cdn.example.com/data.bin" })
      stub_request(:get, "https://cdn.example.com/data.bin")
        .to_return(status: 200, body: "redirected content")

      result = downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      expect(result).to eq("redirected content")
    end

    it "falls back to CAS when direct download fails" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 200, body: "cas data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 8, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      result = downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      expect(result).to eq("cas data")
    end

    it "raises ApiError when CAS reconstruction fails" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 502, body: "bad gateway")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 8, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      expect {
        downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      }.to raise_error(HuggingFaceStorage::ApiError, /Reconstruction fetch failed/)
    end

    it "propagates non-5xx ApiError without falling back to CAS" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 404, body: "not found")

      expect {
        downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      }.to raise_error(HuggingFaceStorage::ApiError, /Download failed/)
    end

    it "propagates redirect limit exceeded without falling back to CAS" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 302, headers: { "Location" => "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin" })

      expect {
        downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      }.to raise_error(HuggingFaceStorage::ApiError, /Redirect cycle detected/)
    end
  end

  describe "XetDownloader#download_data_streaming" do
    it "streams data in chunks via block" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 200, body: "streamed content")

      chunks = []
      downloader.download_data_streaming(TestHelpers::BUCKET_ID, "data.bin") { |chunk| chunks << chunk }
      expect(chunks.join).to eq("streamed content")
    end

    it "falls back to CAS streaming on 5xx error" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 200, body: "cas streamed")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 12, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      chunks = []
      downloader.download_data_streaming(TestHelpers::BUCKET_ID, "data.bin") { |chunk| chunks << chunk }
      expect(chunks.join).to eq("cas streamed")
    end

    it "propagates non-5xx error without CAS fallback" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 404, body: "not found")

      expect {
        downloader.download_data_streaming(TestHelpers::BUCKET_ID, "data.bin") { |_| nil }
      }.to raise_error(HuggingFaceStorage::ApiError)
    end
  end

  # ── Xorb upload failure ──

  describe "xorb/shard upload failures" do
    it "raises ApiError on xorb upload failure" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 500, body: "server error")

      expect {
        uploader.upload_bytes_to_path(TestHelpers::BUCKET_ID, "data", "test.txt")
      }.to raise_error(HuggingFaceStorage::ApiError, /Xorb upload failed/)
    end

    it "raises ApiError on shard upload failure" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 500, body: "shard error")

      expect {
        uploader.upload_bytes_to_path(TestHelpers::BUCKET_ID, "data", "test.txt")
      }.to raise_error(HuggingFaceStorage::ApiError, /Shard upload failed/)
    end
  end

  describe "write token retry on 401" do
    it "invalidates and retries xorb upload on 401" do
      stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
        .to_return(status: 401, body: "unauthorized").then
        .to_return(status: 200, body: "")
      stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards")
        .to_return(status: 200, body: "")

      expect {
        uploader.upload_bytes_to_path(TestHelpers::BUCKET_ID, "small_data", "test_401_retry.txt")
      }.not_to raise_error

      expect(api).to have_received(:get_xet_write_token).at_least(:twice)
    end
  end

  describe "read token retry on 401" do
    it "invalidates and retries CAS download on 401" do
      stub_request(:get, "https://huggingface.co/buckets/#{TestHelpers::BUCKET_ID}/resolve/data.bin")
        .to_return(status: 500, body: "error")
      stub_request(:get, "#{TestHelpers::CAS_URL}/v1/reconstructions/abc123")
        .to_return(status: 401, body: "unauthorized").then
        .to_return(status: 200, body: "recovered data")

      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["data.bin"] })
        .and_return([{ "path" => "data.bin", "size" => 12, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      result = downloader.download_data(TestHelpers::BUCKET_ID, "data.bin")
      expect(result).to eq("recovered data")
      expect(api).to have_received(:get_xet_read_token).at_least(:twice)
    end
  end

  # ── Fetch metadata ──

  describe "XetDownloader#fetch_file_metadata" do
    it "returns file metadata" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{TestHelpers::BUCKET_ID}/paths-info", body: { paths: ["config.json"] })
        .and_return([{ "path" => "config.json", "size" => 660, "xetHash" => "abc123", "mtime" => "2026-01-01" }])

      result = downloader.fetch_file_metadata(TestHelpers::BUCKET_ID, "config.json")
      expect(result[:path]).to eq("config.json")
      expect(result[:size]).to eq(660)
      expect(result[:xet_hash]).to eq("abc123")
    end

    it "raises NotFoundError for missing file" do
      allow(api).to receive(:post).and_return([])

      expect {
        downloader.fetch_file_metadata(TestHelpers::BUCKET_ID, "missing.txt")
      }.to raise_error(HuggingFaceStorage::NotFoundError)
    end
  end
end
