# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Integration: full upload/download round-trip", :integration do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:logger) { HuggingFaceStorage::NullLogger.new }
  let(:api) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger) }
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
  let(:downloader) do
    HuggingFaceStorage::XetDownloader.new(
      api_client: api, token_manager: token_manager,
      endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger
    )
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:upload_service) { HuggingFaceStorage::FileUploadService.new(xet_uploader: uploader, bucket_id: bucket_id, logger: logger) }
  let(:delete_service) { instance_double(HuggingFaceStorage::FileDeleteService) }
  let(:copy_service) { instance_double(HuggingFaceStorage::FileCopyService) }
  let(:fm) do
    HuggingFaceStorage::FileManager.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader, bucket_id: bucket_id, logger: logger,
      upload_service: upload_service, delete_service: delete_service, copy_service: copy_service
    )
  end

  before do
    stub_request(:get, /huggingface\.co\/api\/buckets\/.*\/xet-write-token/)
      .to_return(status: 200, body: JSON.generate(
        "casUrl" => TestHelpers::CAS_URL,
        "accessToken" => "xet_write_abc",
        "exp" => 9999999999
      ), headers: { "Content-Type" => "application/json" })

    stub_request(:get, /huggingface\.co\/api\/buckets\/.*\/xet-read-token/)
      .to_return(status: 200, body: JSON.generate(
        "casUrl" => TestHelpers::CAS_URL,
        "accessToken" => "xet_read_abc",
        "exp" => 9999999999
      ), headers: { "Content-Type" => "application/json" })

    stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/)
      .to_return(status: 200, body: "")

    stub_request(:post, /cas\.huggingface\.co\/v1\/shards/)
      .to_return(status: 200, body: "")

    stub_request(:post, /huggingface\.co\/api\/buckets\/.*\/batch/)
      .to_return(status: 200, body: "")

    stub_request(:post, /huggingface\.co\/api\/buckets\/.*\/paths-info/)
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
  end

  it "uploads a single file via XetUploader and registers via batch" do
    Dir.mktmpdir do |dir|
      local_path = File.join(dir, "test.txt")
      File.write(local_path, "hello integration test")

      result = fm.upload(local_path, "test.txt")
      expect(result[:path]).to eq("test.txt")
      expect(a_request(:post, /xorbs/)).to have_been_made
      expect(a_request(:post, /shards/)).to have_been_made
      expect(a_request(:post, /batch/)).to have_been_made
    end
  end

  it "uploads bytes directly" do
    result = fm.upload_bytes("raw bytes content", "raw.txt")
    expect(result[:path]).to eq("raw.txt")
    expect(result[:size]).to eq(17)
  end

  it "batch uploads multiple files" do
    entries = [
      { data: "file one content".b, remote_path: "batch/a.txt", size: 15 },
      { data: "file two content".b, remote_path: "batch/b.txt", size: 15 }
    ]

    results = uploader.upload_batch(bucket_id, entries)
    expect(results.size).to eq(2)
    expect(results.map { |r| r[:path] }).to contain_exactly("batch/a.txt", "batch/b.txt")
  end
end

RSpec.describe "Integration: Client initialization", :integration do
  it "creates a full client with files and directories managers" do
    client = HuggingFaceStorage.new(
      token: "hf_test",
      namespace: "user",
      bucket: "test-bucket",
      log_level: :fatal
    )

    expect(client.files).to be_a(HuggingFaceStorage::FileManager)
    expect(client.directories).to be_a(HuggingFaceStorage::DirectoryManager)
    expect(client.bucket_id).to eq("user/test-bucket")
    expect(client.config).to be_a(HuggingFaceStorage::Configuration)
  end

  it "accepts custom configuration" do
    config = HuggingFaceStorage::Configuration.new(max_retries: 5)

    client = HuggingFaceStorage.new(
      token: "hf_test",
      namespace: "user",
      bucket: "test-bucket",
      log_level: :fatal,
      config: config
    )

    expect(client.config.max_retries).to eq(5)
  end
end

RSpec.describe "Integration: error handling chain", :integration do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:logger) { HuggingFaceStorage::NullLogger.new }
  let(:api) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger) }

  it "raises AuthenticationError on 401" do
    stub_request(:get, /huggingface\.co\/api\/buckets/)
      .to_return(status: 401, body: '{"error":"unauthorized"}')

    expect { api.get("/api/buckets/user/bucket") }
      .to raise_error(HuggingFaceStorage::AuthenticationError)
  end

  it "raises NotFoundError on 404" do
    stub_request(:get, /huggingface\.co\/api\/buckets/)
      .to_return(status: 404, body: '{"error":"not found"}')

    expect { api.get("/api/buckets/user/bucket") }
      .to raise_error(HuggingFaceStorage::NotFoundError)
  end

  it "raises ConflictError on 409" do
    stub_request(:get, /huggingface\.co\/api\/buckets/)
      .to_return(status: 409, body: '{"error":"conflict"}')

    expect { api.get("/api/buckets/user/bucket") }
      .to raise_error(HuggingFaceStorage::ConflictError)
  end

  it "raises ApiError on 500 with status and body" do
    allow(api).to receive(:sleep)
    stub_request(:get, /huggingface\.co\/api\/buckets/)
      .to_return(status: 500, body: '{"error":"internal"}')

    begin
      api.get("/api/buckets/user/bucket")
    rescue HuggingFaceStorage::ApiError => e
      expect(e.status).to eq(500)
      expect(e.body).to include("internal")
    end
  end
end

RSpec.describe "Integration: CancelToken across operations", :integration do
  it "cancels batch operation mid-flight" do
    token = HuggingFaceStorage::CancelToken.new
    token.cancel!

    auth = HuggingFaceStorage::Authentication.new(token: "hf_test")
    logger = HuggingFaceStorage::NullLogger.new
    api = HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger)

    stub_request(:post, /batch/).to_return(status: 200, body: "")

    expect {
      api.batch("user/bucket", [
        { type: "addFile", path: "a.txt" },
        { type: "addFile", path: "b.txt" }
      ], cancel_token: token)
    }.to raise_error(HuggingFaceStorage::CancelledError)
  end
end

RSpec.describe "Integration: BatchResult tracking", :integration do
  it "tracks successes and failures" do
    result = HuggingFaceStorage::BatchResult.new
    result.add_success({ type: "addFile", path: "a.txt" })
    result.add_success({ type: "addFile", path: "b.txt" })
    result.add_failure("c.txt", "conflict")

    expect(result.success_count).to eq(2)
    expect(result.failure_count).to eq(1)
    expect(result.success?).to be false
    expect { result.raise_if_any! }.to raise_error(HuggingFaceStorage::PartialFailureError)
  end

  it "merges results" do
    r1 = HuggingFaceStorage::BatchResult.new
    r1.add_success({ type: "addFile", path: "a.txt" })

    r2 = HuggingFaceStorage::BatchResult.new
    r2.add_success({ type: "addFile", path: "b.txt" })

    r1.merge!(r2)
    expect(r1.success_count).to eq(2)
  end
end

RSpec.describe "Integration: XetLazyFile", :integration do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:logger) { HuggingFaceStorage::NullLogger.new }
  let(:api) { HuggingFaceStorage::ApiClient.new(auth: auth, logger: logger) }
  let(:hasher) { HuggingFaceStorage::XetHasher.new }
  let(:serializer) { HuggingFaceStorage::XetSerializer.new(hasher) }
  let(:token_manager) { HuggingFaceStorage::XetTokenManager.new(api_client: api, logger: logger) }
  let(:downloader) do
    HuggingFaceStorage::XetDownloader.new(
      api_client: api, token_manager: token_manager,
      endpoint: HuggingFaceStorage::ApiClient::DEFAULT_BASE_URL, logger: logger
    )
  end

  it "fetches metadata lazily without downloading content" do
    stub_request(:post, /paths-info/)
      .to_return(status: 200, body: JSON.generate([
        { "path" => "models/config.json", "size" => 660, "xetHash" => "abc123", "mtime" => "2026-01-01" }
      ]), headers: { "Content-Type" => "application/json" })

    lazy = HuggingFaceStorage::XetLazyFile.new(
      bucket_id: TestHelpers::BUCKET_ID,
      remote_path: "models/config.json",
      api_client: api,
      xet_downloader: downloader
    )

    expect(lazy.size).to eq(660)
    expect(lazy.xet_hash).to eq("abc123")
    expect(lazy.mtime).to eq("2026-01-01")
    expect(a_request(:post, /paths-info/)).to have_been_made.once
  end
end
