# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe HuggingFaceStorage::XetLazyFile do
  let(:api) do
    instance_double(HuggingFaceStorage::ApiClient).tap do |a|
      allow(a).to receive(:post)
        .with("/api/buckets/test-user/test-bucket/paths-info", body: { paths: ["data/file.txt"] })
        .and_return([{
          "path" => "data/file.txt",
          "size" => 1024,
          "xetHash" => "abc123def456",
          "mtime" => "2026-01-01T00:00:00Z"
        }])
    end
  end
  let(:xet_downloader) do
    instance_double(HuggingFaceStorage::XetDownloader).tap do |x|
      allow(x).to receive(:download_data)
        .with("test-user/test-bucket", "data/file.txt")
        .and_return("file content here")
      allow(x).to receive(:download_data_streaming) do |_, _, **, &block|
        block.call("file ")
        block.call("content ")
        block.call("here")
      end
    end
  end

  let(:lazy) do
    described_class.new(
      bucket_id: "test-user/test-bucket",
      remote_path: "data/file.txt",
      api_client: api,
      xet_downloader: xet_downloader
    )
  end

  describe "#path" do
    it "returns the remote path" do
      expect(lazy.path).to eq("data/file.txt")
    end
  end

  describe "#metadata" do
    it "fetches metadata lazily" do
      expect(api).not_to have_received(:post)
      meta = lazy.metadata
      expect(meta[:size]).to eq(1024)
      expect(meta[:xet_hash]).to eq("abc123def456")
      expect(api).to have_received(:post).once
    end

    it "caches metadata on subsequent calls" do
      lazy.metadata
      lazy.metadata
      expect(api).to have_received(:post).once
    end
  end

  describe "#size" do
    it "returns size from metadata" do
      expect(lazy.size).to eq(1024)
    end
  end

  describe "#xet_hash" do
    it "returns xet hash from metadata" do
      expect(lazy.xet_hash).to eq("abc123def456")
    end
  end

  describe "#mtime" do
    it "returns mtime from metadata" do
      expect(lazy.mtime).to eq("2026-01-01T00:00:00Z")
    end
  end

  describe "#content" do
    it "downloads content lazily" do
      expect(xet_downloader).not_to have_received(:download_data)
      content = lazy.content
      expect(content).to eq("file content here")
      expect(xet_downloader).to have_received(:download_data).once
    end

    it "caches content on subsequent calls" do
      lazy.content
      lazy.content
      expect(xet_downloader).to have_received(:download_data).once
    end

    it "downloads content only once when accessed concurrently" do
      entered = Queue.new
      release = Queue.new
      threads = []

      allow(xet_downloader).to receive(:download_data) do
        entered << true
        release.pop
        "file content here"
      end

      begin
        threads = 2.times.map { Thread.new { lazy.content } }
        Timeout.timeout(1) { sleep 0.01 until entered.size == 1 } # timeout(1) prevents indefinite hang

        2.times { release << true }
        expect(threads.map(&:value)).to eq(["file content here", "file content here"])
        expect(xet_downloader).to have_received(:download_data).once
      ensure
        2.times { release << true }
        threads.each(&:join)
      end
    end
  end

  describe "#content_streaming" do
    it "streams content in chunks via block" do
      chunks = []
      lazy.content_streaming { |chunk| chunks << chunk }
      expect(chunks).to eq(["file ", "content ", "here"])
    end

    it "returns an Enumerator when no block given" do
      enum = lazy.content_streaming
      expect(enum).to be_a(Enumerator)
      expect(enum.to_a).to eq(["file ", "content ", "here"])
    end

    it "does not cache content in @content" do
      lazy.content_streaming { |_| nil }
      expect(lazy.loaded?).to be false
    end
  end

  describe "#read" do
    it "reads content with block and returns bytesize" do
      chunks = []
      bytesize = lazy.read { |chunk| chunks << chunk }
      expect(chunks).to eq(["file content here"])
      expect(bytesize).to eq("file content here".bytesize)
    end

    it "returns content string without block" do
      expect(lazy.read).to eq("file content here")
    end
  end

  describe "#save_to" do
    it "saves content to a local file" do
      Dir.mktmpdir do |dir|
        local = File.join(dir, "out.txt")
        lazy.save_to(local)
        expect(File.read(local)).to eq("file content here")
      end
    end
  end

  describe "#to_s" do
    it "shows path and load state" do
      expect(lazy.to_s).to include("data/file.txt")
      expect(lazy.to_s).to include("loaded=no")
    end
  end

  describe "#inspect" do
    it "aliases to to_s" do
      expect(lazy.inspect).to eq(lazy.to_s)
    end
  end

  describe "#loaded?" do
    it "returns false before content is accessed" do
      expect(lazy.loaded?).to be false
    end

    it "returns true after content is accessed" do
      lazy.content
      expect(lazy.loaded?).to be true
    end
  end

  describe "#release!" do
    it "clears cached content and metadata" do
      lazy.content
      lazy.metadata
      expect(lazy.loaded?).to be true

      lazy.release!
      expect(lazy.loaded?).to be false
    end

    it "allows re-fetching after release" do
      lazy.content
      lazy.release!
      lazy.content
      expect(xet_downloader).to have_received(:download_data).twice
    end

    it "returns self for chaining" do
      expect(lazy.release!).to be(lazy)
    end
  end
end
