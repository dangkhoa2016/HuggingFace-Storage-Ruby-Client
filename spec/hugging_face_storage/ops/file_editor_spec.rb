# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::FileEditor do
  subject(:editor) do
    described_class.new(
      api_client: api, xet_uploader: uploader, xet_downloader: downloader,
      bucket_id: bucket_id, config: config, logger: logger
    )
  end

  let(:api) { instance_double(HuggingFaceStorage::ApiClient) }
  let(:uploader) { instance_double(HuggingFaceStorage::XetUploader) }
  let(:downloader) { instance_double(HuggingFaceStorage::XetDownloader) }
  let(:bucket_id) { "test-user/test-bucket" }
  let(:config) { HuggingFaceStorage::Configuration.new }
  let(:logger) { null_logger }

  describe "#initialize" do
    it "stores api_client" do
      expect(editor.instance_variable_get(:@api)).to be(api)
    end

    it "stores xet_uploader" do
      expect(editor.instance_variable_get(:@xet_uploader)).to be(uploader)
    end

    it "stores xet_downloader" do
      expect(editor.instance_variable_get(:@xet_downloader)).to be(downloader)
    end

    it "stores bucket_id" do
      expect(editor.instance_variable_get(:@bucket_id)).to eq("test-user/test-bucket")
    end

    it "stores config" do
      expect(editor.instance_variable_get(:@config)).to be(config)
    end

    it "stores logger" do
      expect(editor.instance_variable_get(:@logger)).to be(logger)
    end
  end

  describe "#edit" do
    before do
      allow(downloader).to receive(:download_data).and_return("hello world")
      allow(uploader).to receive(:upload_data).and_return({ xet_hash: "newhash", size: 11 })
      allow(api).to receive(:post).and_return([])
    end

    it "downloads, applies edits, and uploads" do
      result = editor.edit("config.txt", edits: [{ start: 0, end: 5, content: "HELLO" }])

      expect(downloader).to have_received(:download_data).with(bucket_id, "config.txt", cancel_token: nil)
      expect(uploader).to have_received(:upload_data).with(bucket_id, "HELLO world", "config.txt", cancel_token: nil)
      expect(result).to eq({ xet_hash: "newhash", size: 11 })
    end

    it "applies no-effect edit and returns upload result" do
      edits = [{ start: 0, end: 0, content: "" }]
      result = editor.edit("config.txt", edits: edits)

      expect(uploader).to have_received(:upload_data).with(bucket_id, "hello world", "config.txt", cancel_token: nil)
      expect(result[:xet_hash]).to eq("newhash")
    end

    it "walks back through sorted edits in reverse order" do
      allow(downloader).to receive(:download_data).and_return("abcdef")
      edits = [
        { start: 3, end: 6, content: "DEF" },
        { start: 0, end: 3, content: "ABC" }
      ]
      editor.edit("f.txt", edits: edits)
      expect(uploader).to have_received(:upload_data).with(bucket_id, "ABCDEF", "f.txt", cancel_token: nil)
    end

    it "passes cancel_token through" do
      token = HuggingFaceStorage::CancelToken.new
      editor.edit("config.txt", edits: [{ start: 0, end: 1, content: "X" }], cancel_token: token)

      expect(downloader).to have_received(:download_data).with(bucket_id, "config.txt",
hash_including(cancel_token: token))
      expect(uploader).to have_received(:upload_data).with(bucket_id, anything, "config.txt",
hash_including(cancel_token: token))
    end

    it "raises ArgumentError when edits is not an Array" do
      expect { editor.edit("f.txt", edits: "bad") }
        .to raise_error(ArgumentError, /edits must be a non-empty Array/)
    end

    it "raises ArgumentError when edits is empty" do
      expect { editor.edit("f.txt", edits: []) }
        .to raise_error(ArgumentError, /edits must be a non-empty Array/)
    end

    it "raises ArgumentError when edit entry is not a Hash" do
      expect { editor.edit("f.txt", edits: ["bad"]) }
        .to raise_error(ArgumentError, /edit\[0\] must be a Hash/)
    end

    it "raises ArgumentError when edit has no start or offset" do
      expect { editor.edit("f.txt", edits: [{ content: "x" }]) }
        .to raise_error(ArgumentError, /requires :start or :offset/)
    end

    it "raises ArgumentError when start is negative" do
      expect { editor.edit("f.txt", edits: [{ start: -1 }]) }
        .to raise_error(ArgumentError, /:start must be a non-negative Integer/)
    end

    it "supports :offset alias for :start" do
      result = editor.edit("config.txt", edits: [{ offset: 0, end: 5, content: "HELLO" }])

      expect(uploader).to have_received(:upload_data).with(bucket_id, "HELLO world", "config.txt", cancel_token: nil)
      expect(result[:xet_hash]).to eq("newhash")
    end

    it "applies replace-type edits by finding and replacing text" do
      result = editor.edit("config.txt", edits: [{ type: "replace", old: "hello", new: "HELLO" }])

      expect(uploader).to have_received(:upload_data).with(bucket_id, "HELLO world", "config.txt", cancel_token: nil)
      expect(result[:xet_hash]).to eq("newhash")
    end

    it "applies replace-type with empty replacement" do
      editor.edit("config.txt", edits: [{ type: "replace", old: "hello", new: "" }])

      expect(uploader).to have_received(:upload_data).with(bucket_id, " world", "config.txt", cancel_token: nil)
    end

    it "replaces all occurrences of the pattern" do
      allow(downloader).to receive(:download_data).and_return("foo bar foo baz")
      editor.edit("f.txt", edits: [{ type: "replace", old: "foo", new: "FOO" }])

      expect(uploader).to have_received(:upload_data).with(bucket_id, "FOO bar FOO baz", "f.txt", cancel_token: nil)
    end

    it "raises ArgumentError when replace pattern is not found" do
      expect {
        editor.edit("config.txt", edits: [{ type: "replace", old: "NONEXISTENT", new: "X" }])
      }.to raise_error(ArgumentError, /pattern not found/)
    end

    it "respects max_replacements limit" do
      allow(downloader).to receive(:download_data).and_return("foo foo foo foo")
      edits = [{ type: "replace", old: "foo", new: "FOO", max_replacements: 2 }]
      editor.edit("f.txt", edits: edits)

      expect(uploader).to have_received(:upload_data).with(bucket_id, "FOO FOO foo foo", "f.txt", cancel_token: nil)
    end

    it "raises when replace :old is not a non-empty String" do
      expect {
        editor.edit("f.txt", edits: [{ type: "replace", old: "", new: "X" }])
      }.to raise_error(ArgumentError, /:old must be a non-empty String/)
    end

    context "with cancelled token" do
      it "raises before downloading" do
        token = HuggingFaceStorage::CancelToken.new
        token.cancel!

        expect { editor.edit("f.txt", edits: [{ start: 0, end: 1, content: "X" }], cancel_token: token) }
          .to raise_error(HuggingFaceStorage::CancelledError)
      end
    end

    describe "size guard" do
      before do
        allow(api).to receive(:post)
          .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["huge.bin"] }))
          .and_return([{ "type" => "file", "path" => "huge.bin", "size" => 100 * 1024 * 1024 }])
      end

      it "refuses to edit a file larger than config.max_edit_file_size" do
        expect { editor.edit("huge.bin", edits: [{ start: 0, end: 1, content: "X" }]) }
          .to raise_error(HuggingFaceStorage::Error, /exceeds max_edit_file_size/)
        expect(downloader).not_to have_received(:download_data)
      end

      it "allows edit when file size equals the limit exactly" do
        allow(api).to receive(:post)
          .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["exact.bin"] }))
          .and_return([{ "type" => "file", "path" => "exact.bin", "size" => 50 * 1024 * 1024 }])

        result = editor.edit("exact.bin", edits: [{ start: 0, end: 5, content: "HELLO" }])
        expect(uploader).to have_received(:upload_data)
        expect(result[:xet_hash]).to eq("newhash")
      end
    end

    it "skips size guard when max_edit_file_size is nil" do
      cfg = HuggingFaceStorage::Configuration.new(max_edit_file_size: nil)
      ed = described_class.new(
        api_client: api, xet_uploader: uploader, xet_downloader: downloader,
        bucket_id: bucket_id, config: cfg, logger: logger
      )

      result = ed.edit("config.txt", edits: [{ start: 0, end: 5, content: "HELLO" }])
      expect(uploader).to have_received(:upload_data)
      expect(result[:xet_hash]).to eq("newhash")
    end

    it "skips size guard when fetch_info raises an error" do
      allow(api).to receive(:post)
        .with("/api/buckets/#{bucket_id}/paths-info", hash_including(body: { paths: ["broken.bin"] }))
        .and_raise(HuggingFaceStorage::Error, "API unavailable")

      result = editor.edit("broken.bin", edits: [{ start: 0, end: 5, content: "HELLO" }])
      expect(uploader).to have_received(:upload_data)
      expect(result[:xet_hash]).to eq("newhash")
    end
  end
end
