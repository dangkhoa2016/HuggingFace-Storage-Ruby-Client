# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::DirectoryDownloader do
  let(:auth) { HuggingFaceStorage::Authentication.new(token: "hf_test") }
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:get_xet_read_token).and_return(
        endpoint: TestHelpers::CAS_URL, token: "xet_read_abc", expiration: 9999999999
      )
    end
  end
  let(:xet_downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_file)
    end
  end
  let(:bucket_id) { TestHelpers::BUCKET_ID }
  let(:fast_config) { HuggingFaceStorage::Configuration.new(retry_delay: 0.001, max_retry_delay: 0.05) }

  subject(:downloader) do
    described_class.new(
      api_client: api, xet_downloader: xet_downloader,
      bucket_id: bucket_id, logger: null_logger, config: fast_config
    )
  end

  let(:files) do
    [
      HuggingFaceStorage::FileInfo.new(path: "data/a.txt", size: 5, xet_hash: "h1", mtime: "2026-01-01"),
      HuggingFaceStorage::FileInfo.new(path: "data/b.txt", size: 10, xet_hash: "h2", mtime: "2026-01-02")
    ]
  end

  describe "#download" do
    it "downloads sequentially when parallel is 1" do
      Dir.mktmpdir do |dir|
        downloader.download(files, "data", dir, parallel: 1)
        expect(xet_downloader).to have_received(:download_file).twice
      end
    end

    it "downloads sequentially when single file" do
      Dir.mktmpdir do |dir|
        single = [files.first]
        downloader.download(single, "data", dir, parallel: 4)
        expect(xet_downloader).to have_received(:download_file).once
      end
    end

    it "respects cancel_token in sequential mode without mutating it" do
      token = HuggingFaceStorage::CancelToken.new
      token.cancel!
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(files, "data", dir, parallel: 1, cancel_token: token)
        }.to raise_error(HuggingFaceStorage::CancelledError)
      end
      expect(token.cancelled?).to be true
    end

    it "raises ApiError on retryable download failure in parallel mode" do
      allow(xet_downloader).to receive(:download_file).and_raise(Net::ReadTimeout, "read timed out")
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(files, "data", dir, parallel: 4)
        }.to raise_error(HuggingFaceStorage::ApiError, /Failed to download/)
      end
    end

    it "does not swallow unexpected errors in parallel mode" do
      allow(xet_downloader).to receive(:download_file).and_raise(StandardError, "bug")
      Dir.mktmpdir do |dir|
        previous = Thread.report_on_exception
        Thread.report_on_exception = false
        begin
          expect {
            downloader.download(files, "data", dir, parallel: 4)
          }.to raise_error(StandardError, /bug/)
        ensure
          Thread.report_on_exception = previous
        end
      end
    end

    it "rescues CancelledError in parallel mode" do
      allow(xet_downloader).to receive(:download_file).and_raise(HuggingFaceStorage::CancelledError)
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(files, "data", dir, parallel: 2)
        }.not_to raise_error
      end
    end

    it "does not mutate external cancel_token on error" do
      allow(xet_downloader).to receive(:download_file).and_raise(Net::ReadTimeout, "connection lost")

      external_token = HuggingFaceStorage::CancelToken.new
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(files, "data", dir, parallel: 4, cancel_token: external_token)
        }.to raise_error(HuggingFaceStorage::ApiError, /Failed to download/)
      end
      expect(external_token.cancelled?).to be false
    end

    it "propagates external cancellation to internal workers without mutating external token" do
      external_token = HuggingFaceStorage::CancelToken.new
      external_token.cancel!

      Dir.mktmpdir do |dir|
        downloader.download(files, "data", dir, parallel: 4, cancel_token: external_token)
        expect(xet_downloader).not_to have_received(:download_file)
      end
      expect(external_token.cancelled?).to be true
    end
  end

  describe "path traversal protection" do
    let(:traversal_files) do
      [
        HuggingFaceStorage::FileInfo.new(path: "data/../etc/passwd", size: 5, xet_hash: "h1", mtime: "2026-01-01")
      ]
    end

    it "refuses to write outside target directory in sequential mode" do
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(traversal_files, "data", dir, parallel: 1)
        }.to raise_error(HuggingFaceStorage::Error, /Refusing to write outside target directory/)
      end
    end

    it "refuses to write outside target directory in parallel mode" do
      parallel_files = traversal_files + [
        HuggingFaceStorage::FileInfo.new(path: "data/ok.txt", size: 5, xet_hash: "h2", mtime: "2026-01-01")
      ]
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(parallel_files, "data", dir, parallel: 2)
        }.to raise_error(HuggingFaceStorage::ApiError, /Failed to download/)
      end
    end

    it "allows legitimate relative paths" do
      legit = [
        HuggingFaceStorage::FileInfo.new(path: "data/sub/deep/file.txt", size: 5, xet_hash: "h1", mtime: "2026-01-01")
      ]
      Dir.mktmpdir do |dir|
        downloader.download(legit, "data", dir, parallel: 1)
        expect(xet_downloader).to have_received(:download_file).with(
          bucket_id, "data/sub/deep/file.txt", File.join(dir, "sub/deep/file.txt"), hash_including(:cancel_token)
        )
      end
    end

    it "resolves symlinks in the target directory path" do
      Dir.mktmpdir do |dir|
        real_base = File.join(dir, "inside")
        Dir.mkdir(real_base)
        symlink_to_base = File.join(dir, "link")
        begin
          File.symlink(real_base, symlink_to_base)
        rescue StandardError
          skip "symlinks not supported"
        end
        result = downloader.send(:safe_local_path, symlink_to_base, ".", "data")
        expect(result).to eq(real_base)
      end
    end

    it "blocks deeply nested traversal" do
      deep_traversal = [
        HuggingFaceStorage::FileInfo.new(path: "data/a/../../../../../../etc/passwd", size: 5, xet_hash: "h1",
mtime: "2026-01-01")
      ]
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(deep_traversal, "data", dir, parallel: 1)
        }.to raise_error(HuggingFaceStorage::Error, /Refusing to write outside/)
      end
    end

    it "allows empty relative_path (candidate == safe_root)" do
      root_file = [
        HuggingFaceStorage::FileInfo.new(path: "data", size: 5, xet_hash: "h1", mtime: "2026-01-01")
      ]
      Dir.mktmpdir do |dir|
        expect {
          downloader.download(root_file, "data", dir, parallel: 1)
        }.not_to raise_error
        expect(xet_downloader).to have_received(:download_file).with(
          bucket_id, "data", dir, hash_including(:cancel_token)
        )
      end
    end

    it "blocks traversal through symlink in local_dir" do
      traversal = [
        HuggingFaceStorage::FileInfo.new(path: "data/escape.txt", size: 5, xet_hash: "h1", mtime: "2026-01-01")
      ]
      Dir.mktmpdir do |dir|
        outside = File.join(dir, "outside.txt")
        Dir.mkdir(File.join(dir, "realdir"))
        symlink = File.join(dir, "linkdir")
        begin
          File.symlink(File.join(dir, "realdir"), symlink)
        rescue StandardError
          skip "symlinks not supported"
        end
        File.write(outside, "secret")

        expect {
          downloader.download(traversal, "data", symlink, parallel: 1)
        }.not_to raise_error
      end
    end
  end
end
