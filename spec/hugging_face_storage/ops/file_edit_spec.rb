# frozen_string_literal: true

require "spec_helper"

RSpec.describe "FileManager#edit" do
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
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:post).and_return([])
    end
  end
  let(:uploader) do
    instance_double(HuggingFaceStorage::XetUploader).tap do |x|
      allow(x).to receive(:upload_data).and_return({ xet_hash: "newhash", size: 11 })
    end
  end
  let(:downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_data).and_return("hello world")
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:upload_service) { instance_double(HuggingFaceStorage::FileUploadService) }
  let(:delete_service) { instance_double(HuggingFaceStorage::FileDeleteService) }
  let(:copy_service) { instance_double(HuggingFaceStorage::FileCopyService) }
  let(:fm) {
    HuggingFaceStorage::FileManager.new(api_client: api, xet_uploader: uploader, xet_downloader: downloader, bucket_id: bucket_id, logger: logger,
                                                  upload_service: upload_service, delete_service: delete_service, copy_service: copy_service)
  }

  it "downloads, applies edits, and re-uploads" do
    edits = [{ start: 0, end: 5, content: "HELLO" }]
    result = fm.edit("config.txt", edits: edits)

    expect(downloader).to have_received(:download_data).with(
      bucket_id, "config.txt", cancel_token: nil
    )
    expect(uploader).to have_received(:upload_data).with(
      bucket_id, "HELLO world", "config.txt", cancel_token: nil
    )
    expect(result[:xet_hash]).to eq("newhash")
  end

  it "passes cancel_token through" do
    token = HuggingFaceStorage::CancelToken.new
    fm.edit("config.txt", edits: [{ start: 0, end: 1, content: "X" }], cancel_token: token)

    expect(downloader).to have_received(:download_data).with(
      bucket_id, "config.txt", hash_including(cancel_token: token)
    )
    expect(uploader).to have_received(:upload_data).with(
      bucket_id, anything, "config.txt", hash_including(cancel_token: token)
    )
  end

  it "raises ArgumentError when edits is not an Array" do
    expect { fm.edit("f.txt", edits: "bad") }
      .to raise_error(ArgumentError, /edits must be a non-empty Array/)
  end

  it "raises ArgumentError when edits is empty" do
    expect { fm.edit("f.txt", edits: []) }
      .to raise_error(ArgumentError, /edits must be a non-empty Array/)
  end

  it "raises ArgumentError when edit entry is not a Hash" do
    expect { fm.edit("f.txt", edits: ["bad"]) }
      .to raise_error(ArgumentError, /edit\[0\] must be a Hash/)
  end

  it "raises ArgumentError when edit entry has no start or offset" do
    expect { fm.edit("f.txt", edits: [{ content: "x" }]) }
      .to raise_error(ArgumentError, /requires :start or :offset/)
  end

  it "raises ArgumentError when start is negative" do
    expect { fm.edit("f.txt", edits: [{ start: -1 }]) }
      .to raise_error(ArgumentError, /:start must be a non-negative Integer/)
  end

  it "applies replace-type edits by finding and replacing text" do
    edits = [{ type: "replace", old: "hello", new: "HELLO" }]
    result = fm.edit("config.txt", edits: edits)

    expect(downloader).to have_received(:download_data).with(
      bucket_id, "config.txt", cancel_token: nil
    )
    expect(uploader).to have_received(:upload_data).with(
      bucket_id, "HELLO world", "config.txt", cancel_token: nil
    )
    expect(result[:xet_hash]).to eq("newhash")
  end

  it "applies replace-type with empty replacement" do
    edits = [{ type: "replace", old: "hello", new: "" }]
    fm.edit("config.txt", edits: edits)

    expect(uploader).to have_received(:upload_data).with(
      bucket_id, " world", "config.txt", cancel_token: nil
    )
  end

  it "replaces all occurrences of the pattern" do
    allow(downloader).to receive(:download_data).and_return("foo bar foo baz")
    edits = [{ type: "replace", old: "foo", new: "FOO" }]
    fm.edit("f.txt", edits: edits)

    expect(uploader).to have_received(:upload_data).with(
      bucket_id, "FOO bar FOO baz", "f.txt", cancel_token: nil
    )
  end

  it "raises ArgumentError when replace pattern is not found" do
    expect {
      fm.edit("config.txt", edits: [{ type: "replace", old: "NONEXISTENT", new: "X" }])
    }.to raise_error(ArgumentError, /pattern not found/)
  end

  it "refuses to edit a file larger than config.max_edit_file_size" do
    allow(api).to receive(:post)
      .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["huge.bin"] }))
      .and_return([{ "type" => "file", "path" => "huge.bin", "size" => 100 * 1024 * 1024 }])

    expect do
      fm.edit("huge.bin", edits: [{ start: 0, end: 1, content: "X" }])
    end.to raise_error(HuggingFaceStorage::Error, /exceeds max_edit_file_size/)
    expect(downloader).not_to have_received(:download_data)
  end

  it "skips size guard when max_edit_file_size is nil" do
    cfg = HuggingFaceStorage::Configuration.new(max_edit_file_size: nil)
    fm2 = HuggingFaceStorage::FileManager.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader,
      bucket_id: bucket_id, config: cfg, logger: logger,
      upload_service: upload_service, delete_service: delete_service, copy_service: copy_service
    )
    result = fm2.edit("config.txt", edits: [{ start: 0, end: 5, content: "HELLO" }])
    expect(uploader).to have_received(:upload_data)
    expect(result[:xet_hash]).to eq("newhash")
  end

  it "skips size guard when fetch_info raises an error" do
    allow(api).to receive(:post)
      .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["broken.bin"] }))
      .and_raise(HuggingFaceStorage::Error, "API unavailable")

    result = fm.edit("broken.bin", edits: [{ start: 0, end: 5, content: "HELLO" }])
    expect(uploader).to have_received(:upload_data)
    expect(result[:xet_hash]).to eq("newhash")
  end

  it "allows edit when file size equals the limit exactly" do
    allow(api).to receive(:post)
      .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["exact.bin"] }))
      .and_return([{ "type" => "file", "path" => "exact.bin", "size" => 50 * 1024 * 1024 }])

    result = fm.edit("exact.bin", edits: [{ start: 0, end: 5, content: "HELLO" }])
    expect(uploader).to have_received(:upload_data)
    expect(result[:xet_hash]).to eq("newhash")
  end
end

# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe "FileManager#edit integration" do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test_token") }
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:logger) { null_logger }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_write_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_write_abc", expiration: 9999999999
      )
      allow(a).to receive(:get_xet_read_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_read_abc", expiration: 9999999999
      )
      allow(a).to receive(:batch).and_return(HuggingFaceStorage::BatchResult.new)
      allow(a).to receive(:post).and_return([])
      allow(a).to receive(:request_with_redirect) do |uri, **kwargs, &block|
        HuggingFaceStorage::ApiClient.new(auth: auth, logger: null_logger).request_with_redirect(uri, **kwargs, &block)
      end
    end
  end
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
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:upload_serv) { instance_double(HuggingFaceStorage::FileUploadService) }
  let(:delete_serv) { instance_double(HuggingFaceStorage::FileDeleteService) }
  let(:copy_serv) { instance_double(HuggingFaceStorage::FileCopyService) }
  let(:fm) {
    HuggingFaceStorage::FileManager.new(api_client: api, xet_uploader: uploader, xet_downloader: downloader, bucket_id: bucket_id, logger: logger,
                                                  upload_service: upload_serv, delete_service: delete_serv, copy_service: copy_serv)
  }

  before do
    stub_request(:post, /cas\.huggingface\.co\/v1\/xorbs/).to_return(status: 200, body: "")
    stub_request(:post, "#{TestHelpers::CAS_URL}/v1/shards").to_return(status: 200, body: "")
    stub_request(:get, "https://huggingface.co/buckets/#{bucket_id}/resolve/readme.txt")
      .to_return(status: 200, body: "hello world")
  end

  it "applies edits and re-uploads" do
    result = fm.edit("readme.txt", edits: [{ start: 0, end: 5, content: "HELLO" }])
    expect(result[:xet_hash]).to be_a(String)
    expect(api).to have_received(:batch).with(bucket_id, array_including(
      hash_including(type: "addFile", path: "readme.txt")
    ), hash_including(cancel_token: nil))
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
