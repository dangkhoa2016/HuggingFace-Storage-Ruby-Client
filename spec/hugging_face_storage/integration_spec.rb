# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Integration: full service wiring" do
  let(:token) { "hf_test_token" }
  let(:namespace) { "testuser" }
  let(:bucket_name) { "test-bucket" }
  let(:bucket_id) { "#{namespace}/#{bucket_name}" }
  let(:base) { "https://huggingface.co" }
  let(:cas_url) { "https://cas.huggingface.co" }

  let(:client) do
    HuggingFaceStorage::Client::Builder.new(
      token: token,
      namespace: namespace,
      bucket: bucket_name,
      log_output: StringIO.new
    ).build
  end

  # ── Endpoint helpers ──
  def xet_write_token_url
    "#{base}/api/buckets/#{bucket_id}/xet-write-token"
  end

  def xet_read_token_url
    "#{base}/api/buckets/#{bucket_id}/xet-read-token"
  end

  def batch_url
    "#{base}/api/buckets/#{bucket_id}/batch"
  end

  def paths_info_url
    "#{base}/api/buckets/#{bucket_id}/paths-info"
  end

  def tree_url(path = nil)
    "#{base}/api/buckets/#{bucket_id}/tree#{"/#{path}" if path}"
  end

  def resolve_url(path)
    "#{base}/buckets/#{bucket_id}/resolve/#{path}"
  end

  def bucket_info_url
    "#{base}/api/buckets/#{bucket_id}"
  end

  # ── Stub helpers ──
  def stub_write_token
    stub_request(:get, xet_write_token_url)
      .to_return(status: 200,
                 body: JSON.generate({ casUrl: cas_url, accessToken: "xet_write_token", exp: 9_999_999_999 }),
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_read_token
    stub_request(:get, xet_read_token_url)
      .to_return(status: 200,
                 body: JSON.generate({ casUrl: cas_url, accessToken: "xet_read_token", exp: 9_999_999_999 }),
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_cas_uploads
    stub_request(:post, %r{#{Regexp.escape(cas_url)}/v1/xorbs/default/})
      .to_return(status: 200, body: "")
    stub_request(:post, "#{cas_url}/v1/shards")
      .to_return(status: 200, body: "")
  end

  def stub_batch_success
    stub_request(:post, batch_url)
      .to_return(status: 200,
                 body: JSON.generate([{ "ok" => true }]),
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_paths_info(results)
    stub_request(:post, paths_info_url)
      .to_return(status: 200,
                 body: JSON.generate(results),
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_tree_list(url, entries)
    stub_request(:get, url)
      .to_return(status: 200,
                 body: JSON.generate(entries),
                 headers: { "Content-Type" => "application/json" })
  end

  # ── Section 1: File Operations ──

  describe "file operations" do
    describe "#upload" do
      it "uploads a file successfully through the full pipeline" do
        stub_write_token
        stub_cas_uploads
        stub_batch_success

        Dir.mktmpdir do |dir|
          path = File.join(dir, "hello.txt")
          File.write(path, "integration test data")

          result = client.files.upload(path, "remote/hello.txt")
          expect(result[:path]).to eq("remote/hello.txt")
          expect(result[:local_path]).to eq(path)
        end

        expect(a_request(:get, xet_write_token_url)).to have_been_made
        expect(a_request(:post, %r{#{Regexp.escape(cas_url)}/v1/xorbs/default/})).to have_been_made
        expect(a_request(:post, "#{cas_url}/v1/shards")).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#upload_bytes" do
      it "uploads raw bytes successfully" do
        stub_write_token
        stub_cas_uploads
        stub_batch_success

        result = client.files.upload_bytes("raw data content", "notes/raw.txt")
        expect(result[:path]).to eq("notes/raw.txt")
        expect(result[:size]).to eq(16)

        expect(a_request(:get, xet_write_token_url)).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#download" do
      it "downloads a file successfully" do
        stub_paths_info([{
          "path" => "models/config.json", "type" => "file",
          "size" => 128, "xetHash" => "abc123def456"
        }])
        stub_request(:get, resolve_url("models/config.json"))
          .to_return(status: 200, body: "pretend file content")

        Dir.mktmpdir do |dir|
          local = File.join(dir, "config.json")
          result = client.files.download("models/config.json", local)
          expect(result).to eq(local)
          expect(File.read(local)).to eq("pretend file content")
        end

        expect(a_request(:post, paths_info_url)).to have_been_made
        expect(a_request(:get, resolve_url("models/config.json"))).to have_been_made
      end
    end

    describe "#delete" do
      it "deletes a file successfully" do
        stub_paths_info([{
          "path" => "old/file.txt", "type" => "file",
          "size" => 42, "xetHash" => "xyz789"
        }])
        stub_batch_success

        result = client.files.delete("old/file.txt")
        expect(result).to be true

        expect(a_request(:post, paths_info_url)).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#list" do
      it "lists files at root" do
        stub_tree_list("#{tree_url}?recursive=false", [
          { "type" => "file", "path" => "readme.md", "size" => 512, "xetHash" => "a1" },
          { "type" => "file", "path" => "data.csv", "size" => 2048, "xetHash" => "b2" }
        ])

        files = client.files.list
        expect(files.size).to eq(2)
        expect(files.first).to be_a(HuggingFaceStorage::FileInfo)
        expect(files.map(&:path)).to contain_exactly("readme.md", "data.csv")

        expect(a_request(:get, "#{tree_url}?recursive=false")).to have_been_made
      end
    end

    describe "#exists?" do
      it "returns true when file exists" do
        stub_request(:head, resolve_url("present.txt"))
          .to_return(status: 200, body: "")

        expect(client.files.exists?("present.txt")).to be true
      end

      it "returns false when file does not exist" do
        stub_request(:head, resolve_url("missing.txt"))
          .to_return(status: 404, body: "not found")

        expect(client.files.exists?("missing.txt")).to be false
      end
    end
  end

  # ── Section 2: Directory Operations ──

  describe "directory operations" do
    describe "#create" do
      it "creates a directory that does not yet exist" do
        stub_request(:head, tree_url("new_folder"))
          .to_return(status: 404, body: "not found")
        stub_paths_info([])
        stub_write_token
        stub_cas_uploads
        stub_batch_success

        result = client.directories.create("new_folder")
        expect(result).to be true

        expect(a_request(:head, tree_url("new_folder"))).to have_been_made
        expect(a_request(:post, paths_info_url)).to have_been_made
        expect(a_request(:get, xet_write_token_url)).to have_been_made
      end

      it "returns true immediately when directory already exists" do
        stub_request(:head, tree_url("existing_dir"))
          .to_return(status: 200, body: "")

        result = client.directories.create("existing_dir")
        expect(result).to be true

        expect(a_request(:head, tree_url("existing_dir"))).to have_been_made
        expect(a_request(:post, %r{#{Regexp.escape(cas_url)}/v1/xorbs/})).not_to have_been_made
      end
    end

    describe "#delete" do
      it "deletes a directory and its contents" do
        stub_tree_list("#{tree_url("stuff")}?recursive=true", [
          { "type" => "file", "path" => "stuff/a.txt", "size" => 10, "xetHash" => "h1" },
          { "type" => "file", "path" => "stuff/b.txt", "size" => 20, "xetHash" => "h2" }
        ])
        stub_batch_success

        result = client.directories.delete("stuff")
        expect(result).to be true

        expect(a_request(:get, "#{tree_url("stuff")}?recursive=true")).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#list" do
      it "lists directories at root" do
        stub_tree_list("#{tree_url}?recursive=false", [
          { "type" => "directory", "path" => "models", "uploadedAt" => "2026-01-01" },
          { "type" => "directory", "path" => "data", "uploadedAt" => "2026-01-02" },
          { "type" => "file", "path" => "readme.md", "size" => 100 }
        ])

        dirs = client.directories.list
        expect(dirs.size).to eq(2)
        expect(dirs.first).to be_a(HuggingFaceStorage::DirInfo)
        expect(dirs.map(&:path)).to contain_exactly("models", "data")
      end
    end
  end

  # ── Section 3: Copy Operations ──

  describe "copy operations" do
    describe "#copy (same-bucket)" do
      it "copies a file within the same bucket" do
        stub_request(:head, resolve_url("dest/new.txt"))
          .to_return(status: 404, body: "not found")
        stub_paths_info([{
          "path" => "src/original.txt", "type" => "file",
          "size" => 256, "xetHash" => "hash123"
        }])
        stub_batch_success

        result = client.files.copy("src/original.txt", "dest/new.txt", overwrite: true)
        expect(result[:from]).to eq("src/original.txt")
        expect(result[:to]).to eq("dest/new.txt")

        expect(a_request(:post, paths_info_url)).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#copy_file (cross-repo)" do
      it "copies a single file from another repo" do
        source_type = "model"
        source_repo = "org/my-model"
        source_path = "file.bin"
        destination = "imported/file.bin"

        stub_request(:post, "#{base}/api/models/#{source_repo}/paths-info/main")
          .with(body: "{\"paths\":[\"#{source_path}\"]}")
          .to_return(status: 200,
                     body: JSON.generate([{
                       "path" => source_path, "type" => "file",
                       "size" => 500, "xetHash" => "xet_cross_hash"
                     }]),
                     headers: { "Content-Type" => "application/json" })
        stub_request(:post, paths_info_url)
          .to_return(status: 200,
                     body: JSON.generate([]),
                     headers: { "Content-Type" => "application/json" })
        stub_batch_success

        result = client.files.copy_file(
          source_type: source_type, source_repo: source_repo,
          source_path: source_path, destination: destination
        )
        expect(result[:from]).to eq("#{source_type}:#{source_repo}/#{source_path}")
        expect(result[:to]).to eq(destination)

        expect(a_request(:post, "#{base}/api/models/#{source_repo}/paths-info/main")).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#copy_from (cross-repo batch)" do
      it "copies files from another repo in batch" do
        files = [
          { xet_hash: "abc", destination: "dest/a.bin", source_path: "a.bin", size: 100 },
          { xet_hash: "def", destination: "dest/b.bin", source_path: "b.bin", size: 200 }
        ]

        stub_request(:post, paths_info_url)
          .to_return(status: 200,
                     body: JSON.generate([]),
                     headers: { "Content-Type" => "application/json" })
        stub_batch_success

        result = client.files.copy_from(
          source_type: "model", source_repo: "org/other",
          files: files
        )
        expect(result[:files_copied]).to eq(2)
        expect(result[:from]).to eq("model:org/other")

        expect(a_request(:post, paths_info_url)).to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end

    describe "#copy_from_repo (directory cross-repo)" do
      it "copies a folder from another repo" do
        source_type = "dataset"
        source_repo = "org/my-data"
        source_path = "images"

        stub_tree_list("#{base}/api/datasets/#{source_repo}/tree/main/#{source_path}?recursive=true", [
          { "type" => "file", "path" => "images/logo.png", "size" => 3000, "xetHash" => "hex1" },
          { "type" => "file", "path" => "images/bg.png", "size" => 4000, "xetHash" => "hex2" }
        ])
        stub_request(:post, paths_info_url)
          .to_return(status: 200,
                     body: JSON.generate([]),
                     headers: { "Content-Type" => "application/json" })
        stub_batch_success

        result = client.directories.copy_from_repo(
          source_type: source_type, source_repo: source_repo,
          source_path: source_path, destination_prefix: "my-images"
        )
        expect(result[:files_copied]).to eq(2)
        expect(result[:total]).to eq(2)

        expect(a_request(:get, "#{base}/api/datasets/#{source_repo}/tree/main/#{source_path}?recursive=true"))
          .to have_been_made
        expect(a_request(:post, batch_url)).to have_been_made
      end
    end
  end

  # ── Section 4: Error Handling ──

  describe "error handling" do
    it "raises AuthenticationError for HTTP 401" do
      stub_request(:get, bucket_info_url)
        .to_return(status: 401, body: '{"error":"bad token"}',
                   headers: { "Content-Type" => "application/json" })

      expect { client.bucket_info }
        .to raise_error(HuggingFaceStorage::AuthenticationError, /Authentication failed/)
    end

    it "raises NotFoundError for HTTP 404" do
      stub_request(:get, bucket_info_url)
        .to_return(status: 404, body: '{"error":"no such bucket"}',
                   headers: { "Content-Type" => "application/json" })

      expect { client.bucket_info }
        .to raise_error(HuggingFaceStorage::NotFoundError, /Resource not found/)
    end

    it "raises RateLimitError with retry_after for HTTP 429", :slow do
      retry_config = HuggingFaceStorage::RetryConfig.new(max_retries: 0, retry_delay: 1, max_retry_delay: 1)
      config = HuggingFaceStorage::Configuration.default.with(retry_config: retry_config)
      test_client = HuggingFaceStorage::Client::Builder.new(
        token: token, namespace: namespace, bucket: bucket_name,
        log_output: StringIO.new, config: config
      ).build
      stub_request(:get, bucket_info_url)
        .to_return(status: 429, body: '{"error":"too fast"}',
                   headers: { "Content-Type" => "application/json", "Retry-After" => "1" })

      expect { test_client.bucket_info }
        .to raise_error(HuggingFaceStorage::RateLimitError) { |e|
          expect(e.retry_after).to eq(1)
          expect(e.status).to eq(429)
        }
    end
  end

  # ── Section 5: Configuration ──

  describe "configuration" do
    it "custom configuration propagates to services" do
      config = HuggingFaceStorage::Configuration.default
      custom = config.with(debug_mode: true, base_url: "https://custom.huggingface.co")
      io = StringIO.new

      c = HuggingFaceStorage::Client::Builder.new(
        token: token, namespace: namespace, bucket: bucket_name,
        config: custom, log_output: io
      ).build

      expect(c.config).to be(custom)
      expect(c.debug_mode).to be true
      expect(c.config.base_url).to eq("https://custom.huggingface.co")
    end

    it "debug mode includes backtraces in error messages" do
      config = HuggingFaceStorage::Configuration.default
      custom = config.with(debug_mode: true)
      io = StringIO.new

      c = HuggingFaceStorage::Client::Builder.new(
        token: token, namespace: namespace, bucket: bucket_name,
        config: custom, log_output: io
      ).build

      expect(c.debug_mode).to be true
      expect(c.config.debug_mode).to be true
    end
  end

  # ── Section 6: Bucket-level operations ──

  describe "bucket operations" do
    it "fetches bucket info" do
      stub_request(:get, bucket_info_url)
        .to_return(status: 200,
                   body: JSON.generate({ "id" => bucket_id, "name" => bucket_name, "size" => 1_000_000 }),
                   headers: { "Content-Type" => "application/json" })

      info = client.bucket_info
      expect(info).to be_a(Hash)
      expect(info["id"]).to eq(bucket_id)
      expect(info["name"]).to eq(bucket_name)
    end
  end
end
