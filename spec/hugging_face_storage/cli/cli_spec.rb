# frozen_string_literal: true

require "spec_helper"
require "hugging_face_storage/cli/cli"

RSpec.describe HuggingFaceStorage::CLI do
  let(:files) { instance_double(HuggingFaceStorage::FileManager) }
  let(:directories) { instance_double(HuggingFaceStorage::DirectoryManager) }
  let(:client) do
    instance_double(HuggingFaceStorage::Client, files: files, directories: directories).tap do |c|
      allow(c).to receive(:bucket_info).and_return({ "name" => "b", "size" => 100 })
    end
  end

  before do
    allow(HuggingFaceStorage::CLIFormatter).to receive(:build_client).and_return(client)
    allow(HuggingFaceStorage::CLIFormatter).to receive(:format_output)
  end

  describe "help" do
    it "lists available commands" do
      expect { described_class.start(["help"]) }.to output(/upload/).to_stdout
    end
  end

  describe "upload" do
    it "shows help for upload" do
      expect { described_class.start(["upload"]) }.to output(/BUCKET/).to_stderr
    end

    it "uploads a directory" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/mydir").and_return(true)
      allow(directories).to receive(:upload).and_return({ files_uploaded: 5 })

      expect {
        described_class.start(["upload", "user/bucket", "/tmp/mydir", "remote/dir"])
      }.to output(/Uploaded directory: 5 file/).to_stdout
    end

    it "uploads a glob pattern" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/*.txt").and_return(false)
      allow(files).to receive(:upload).and_return(["f1", "f2"])

      expect {
        described_class.start(["upload", "user/bucket", "/tmp/*.txt", "remote/"])
      }.to output(/Uploaded 2 file/).to_stdout
    end

    it "uploads a single file" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/file.txt").and_return(false)
      allow(files).to receive(:upload)

      expect {
        described_class.start(["upload", "user/bucket", "/tmp/file.txt", "remote/file.txt"])
      }.to output(/Uploaded: \/tmp\/file.txt/).to_stdout
    end

    it "outputs json with --format json" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/mydir").and_return(true)
      allow(directories).to receive(:upload).and_return({ files_uploaded: 3 })

      expect {
        described_class.start(["upload", "user/bucket", "/tmp/mydir", "remote/dir",
                               "--format", "json"])
      }.to output(/"action"/).to_stdout
    end
  end

  describe "download" do
    it "shows help for download" do
      expect { described_class.start(["download"]) }.to output(/BUCKET/).to_stderr
    end

    it "downloads a file" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:download)

      expect {
        described_class.start(["download", "user/bucket", "remote/f.txt", "/tmp/f.txt"])
      }.to output(/Downloaded file/).to_stdout
    end

    it "downloads a directory when file not found" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:exists?).and_return(true)
      allow(directories).to receive(:download)

      expect {
        described_class.start(["download", "user/bucket", "remote/dir", "/tmp/dir"])
      }.to output(/Downloaded directory/).to_stdout
    end

    it "raises error when path not found" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:exists?).and_return(false)

      expect {
        described_class.start(["download", "user/bucket", "missing", "/tmp/out"])
      }.to output(/Not found/).to_stderr
    end
  end

  describe "copy" do
    it "copies within same bucket" do
      allow(directories).to receive(:copy)

      expect {
        described_class.start(["copy", "user/bucket", "src", "dst"])
      }.to output(/Copied: src -> dst/).to_stdout
    end

    it "copies from external repo" do
      allow(directories).to receive(:copy)

      expect {
        described_class.start(["copy", "user/bucket", "src", "dst", "--from_repo", "model:org/repo"])
      }.to output(/Cross-repo copy/).to_stdout
    end
  end

  describe "delete" do
    it "deletes a file" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:delete)

      expect {
        described_class.start(["delete", "user/bucket", "file.txt", "--force"])
      }.to output(/Deleted file: file.txt/).to_stdout
    end

    it "deletes a directory when not a file" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:delete)

      expect {
        described_class.start(["delete", "user/bucket", "dir", "--force"])
      }.to output(/Deleted directory: dir/).to_stdout
    end
  end

  describe "delete --recursive" do
    it "passes recursive: true by default" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:delete)

      described_class.start(["delete", "user/bucket", "dir", "--force"])

      expect(directories).to have_received(:delete).with("dir", hash_including(recursive: true))
    end

    it "passes recursive: false when --no-recursive is given" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:delete)

      described_class.start(["delete", "user/bucket", "dir", "--no-recursive", "--force"])

      expect(directories).to have_received(:delete).with("dir", hash_including(recursive: false))
    end
  end

  describe "move" do
    it "moves a file" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:move)

      expect {
        described_class.start(["move", "user/bucket", "old.txt", "new.txt"])
      }.to output(/Moved: old.txt -> new.txt/).to_stdout
    end

    it "moves a directory when not a file" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:move)

      expect {
        described_class.start(["move", "user/bucket", "old_dir", "new_dir"])
      }.to output(/Moved: old_dir -> new_dir/).to_stdout
    end
  end

  describe "list" do
    it "lists files and directories in table format" do
      file_info = HuggingFaceStorage::EntryInfo.new(type: "file", path: "file.txt", size: 100, xet_hash: "abcdef123456",
mtime: "2026-01-01")
      dir_info = HuggingFaceStorage::EntryInfo.new(type: "directory", path: "models", mtime: "2026-01-15")
      allow(files).to receive(:list_entries).and_return([file_info, dir_info])

      described_class.start(["list", "user/bucket"])
      expect(HuggingFaceStorage::CLIFormatter).to have_received(:format_output)
    end

    it "shows message when no entries found" do
      allow(files).to receive(:list_entries).and_return([])

      expect {
        described_class.start(["list", "user/bucket", "--format", "json"])
      }.to output(/No entries found/).to_stdout
    end
  end

  describe "info" do
    it "shows bucket info when no path given" do
      expect {
        described_class.start(["info", "user/bucket"])
      }.to output(/name/).to_stdout
    end

    it "shows file info when path is a file" do
      allow(files).to receive(:exists?).and_return(true)
      file_meta = HuggingFaceStorage::FileInfo.new(path: "f.txt", size: 100)
      allow(files).to receive(:metadata).and_return(file_meta)

      expect {
        described_class.start(["info", "user/bucket", "f.txt"])
      }.to output(/\{/).to_stdout
    end

    it "shows directory info when path is not a file" do
      allow(files).to receive(:exists?).and_return(false)
      dir_meta = HuggingFaceStorage::DirInfo.new(path: "dir", file_count: 3, total_size: 500)
      allow(directories).to receive(:metadata).and_return(dir_meta)

      expect {
        described_class.start(["info", "user/bucket", "dir"])
      }.to output(/\{/).to_stdout
    end
  end

  describe "snapshot" do
    it "downloads a snapshot" do
      allow(directories).to receive(:snapshot_download)
        .and_return({ files_downloaded: 5, manifest_path: "/tmp/manifest.json" })

      expect {
        described_class.start(["snapshot", "user/bucket", "remote/dir", "/tmp/local"])
      }.to output(/Snapshot complete: 5 file/).to_stdout
    end
  end

  describe "edit" do
    it "edits a remote file" do
      allow(files).to receive(:edit).and_return({ xet_hash: "abc", size: 10 })

      expect {
        described_class.start(["edit", "user/bucket", "config.json",
          "--edits", '[{"type":"replace","old":"v1","new":"v2"}]'])
      }.to output(/Edited: config.json/).to_stdout

      expect(files).to have_received(:edit).with("config.json",
        edits: [{ type: "replace", old: "v1", new: "v2" }])
    end

    it "shows error when --edits option is missing" do
      expect {
        described_class.start(["edit", "user/bucket", "config.json"])
      }.to output(/edits/).to_stderr
    end
  end

  # ── Phase 2: Authentication errors ──

  describe "authentication errors" do
    it "shows error when build_client raises AuthenticationError" do
      allow(HuggingFaceStorage::CLIFormatter).to receive(:build_client)
        .and_raise(HuggingFaceStorage::AuthenticationError, "No token provided")

      expect {
        described_class.start(["list", "user/bucket"])
      }.to output(/No token provided/).to_stderr
    end

    it "shows error when build_client raises ApiError" do
      allow(HuggingFaceStorage::CLIFormatter).to receive(:build_client)
        .and_raise(HuggingFaceStorage::ApiError.new(message: "Connection refused", status: 0, body: nil))

      expect {
        described_class.start(["info", "user/bucket"])
      }.to output(/Connection refused/).to_stderr
    end

    it "shows error when build_client raises NotFoundError" do
      allow(HuggingFaceStorage::CLIFormatter).to receive(:build_client)
        .and_raise(HuggingFaceStorage::NotFoundError, "Resource not found")

      expect {
        described_class.start(["download", "user/bucket", "remote/f.txt", "/tmp/f.txt"])
      }.to output(/Resource not found/).to_stderr
    end
  end

  # ── Phase 2: Flag forwarding ──

  describe "upload with --exclude" do
    it "passes exclude patterns to directory upload" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/mydir").and_return(true)
      allow(directories).to receive(:upload).and_return({ files_uploaded: 3 })

      described_class.start(["upload", "user/bucket", "/tmp/mydir", "remote/dir",
                             "--exclude", "*.log", "--exclude", "*.tmp"])

      expect(directories).to have_received(:upload).with(
        "/tmp/mydir", "remote/dir",
        hash_including(exclude: ["*.log", "*.tmp"])
      )
    end

    it "passes exclude patterns to glob upload" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/*.txt").and_return(false)
      allow(files).to receive(:upload).and_return(["f1"])

      described_class.start(["upload", "user/bucket", "/tmp/*.txt", "remote/",
                             "--exclude", "*.bak"])

      expect(files).to have_received(:upload).with(
        "/tmp/*.txt", "remote/",
        hash_including(exclude: ["*.bak"])
      )
    end
  end

  describe "download with --parallel" do
    it "passes parallel option to directory download" do
      allow(files).to receive(:exists?).and_return(false)
      allow(directories).to receive(:exists?).and_return(true)
      allow(directories).to receive(:download)

      described_class.start(["download", "user/bucket", "remote/dir", "/tmp/dir", "--parallel", "8"])

      expect(directories).to have_received(:download).with(
        "remote/dir", "/tmp/dir", hash_including(parallel: 8)
      )
    end
  end

  # ── Phase 2: Output format ──

  describe "list --format" do
    it "outputs JSON when --format json" do
      file_info = HuggingFaceStorage::EntryInfo.new(type: "file", path: "f.txt", size: 100, xet_hash: "abc123def456",
mtime: "2026-01-01")
      allow(files).to receive(:list_entries).and_return([file_info])

      described_class.start(["list", "user/bucket", "--format", "json"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:format_output).with(
        array_including(array_including("f.txt", 100, "abc123def456", "2026-01-01")),
        "json",
        hash_including(headers: %w[path size xet_hash mtime])
      )
    end

    it "shows message when no entries found (table default)" do
      allow(files).to receive(:list_entries).and_return([])

      expect {
        described_class.start(["list", "user/bucket"])
      }.to output(/No entries found/).to_stdout
    end
  end

  # ── Phase 2: --recursive flag ──

  describe "list --recursive" do
    it "passes recursive: true when --recursive is given" do
      allow(files).to receive(:list_entries).and_return([])

      described_class.start(["list", "user/bucket", "src", "--recursive"])

      expect(files).to have_received(:list_entries).with(hash_including(recursive: true))
    end

    it "passes recursive: true when -r alias is given" do
      allow(files).to receive(:list_entries).and_return([])

      described_class.start(["list", "user/bucket", "-r"])

      expect(files).to have_received(:list_entries).with(hash_including(recursive: true))
    end

    it "defaults recursive to false" do
      allow(files).to receive(:list_entries).and_return([])

      described_class.start(["list", "user/bucket"])

      expect(files).to have_received(:list_entries).with(hash_including(recursive: false))
    end
  end

  # ── Phase 2: snapshot --verify ──

  describe "snapshot with --verify" do
    it "passes verify: true when --verify is given" do
      allow(directories).to receive(:snapshot_download)
        .and_return({ files_downloaded: 5, manifest_path: "/tmp/manifest.json" })

      described_class.start(["snapshot", "user/bucket", "remote/dir", "/tmp/local", "--verify"])

      expect(directories).to have_received(:snapshot_download)
        .with("remote/dir", "/tmp/local", hash_including(verify: true))
    end

    it "passes verify: false by default" do
      allow(directories).to receive(:snapshot_download)
        .and_return({ files_downloaded: 5, manifest_path: "/tmp/manifest.json" })

      described_class.start(["snapshot", "user/bucket", "remote/dir", "/tmp/local"])

      expect(directories).to have_received(:snapshot_download)
        .with("remote/dir", "/tmp/local", hash_including(verify: false))
    end
  end

  # ── Phase 2: Invalid bucket format ──

  describe "invalid bucket format" do
    it "raises ArgumentError for bucket without namespace" do
      expect {
        described_class.start(["list", "invalid"])
      }.to raise_error(ArgumentError, /expected namespace/)
    end

    it "raises ArgumentError for upload with invalid bucket" do
      expect {
        described_class.start(["upload", "nobucket", "/tmp/f.txt", "remote/f.txt"])
      }.to raise_error(ArgumentError, /expected namespace/)
    end
  end

  # ── Phase 2: Token option forwarding ──

  describe "custom --token option" do
    it "passes --token to build_client for upload" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/f.txt").and_return(false)
      allow(files).to receive(:upload)

      described_class.start(["upload", "user/bucket", "/tmp/f.txt", "remote/f.txt",
                             "--token", "hf_custom_abc"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_custom_abc"))
    end

    it "passes --token to build_client for list" do
      allow(files).to receive(:list_entries).and_return([])

      described_class.start(["list", "user/bucket", "--token", "hf_list_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_list_token"))
    end

    it "passes --token to build_client for delete" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:delete)

      described_class.start(["delete", "user/bucket", "file.txt", "--force", "--token", "hf_del_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_del_token"))
    end

    it "passes --token to build_client for copy" do
      allow(directories).to receive(:copy)

      described_class.start(["copy", "user/bucket", "src", "dst", "--token", "hf_copy_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_copy_token"))
    end

    it "passes --token to build_client for move" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:move)

      described_class.start(["move", "user/bucket", "old.txt", "new.txt", "--token", "hf_move_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_move_token"))
    end

    it "passes --token to build_client for snapshot" do
      allow(directories).to receive(:snapshot_download)
        .and_return({ files_downloaded: 1, manifest_path: "/tmp/m.json" })

      described_class.start(["snapshot", "user/bucket", "r/d", "/tmp/l", "--token", "hf_snap_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_snap_token"))
    end

    it "passes --token to build_client for edit" do
      allow(files).to receive(:edit).and_return({ xet_hash: "abc", size: 10 })

      described_class.start(["edit", "user/bucket", "config.json",
        "--edits", '[{"type":"replace","old":"v1","new":"v2"}]',
        "--token", "hf_edit_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_edit_token"))
    end

    it "passes --token to build_client for info" do
      described_class.start(["info", "user/bucket", "--token", "hf_info_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_info_token"))
    end

    it "passes --token to build_client for download" do
      allow(files).to receive(:exists?).and_return(true)
      allow(files).to receive(:download)

      described_class.start(["download", "user/bucket", "r/f.txt", "/tmp/f.txt", "--token", "hf_dl_token"])

      expect(HuggingFaceStorage::CLIFormatter).to have_received(:build_client)
        .with("user/bucket", hash_including(token: "hf_dl_token"))
    end
  end

  # ── Phase 2: Copy --from_repo parsing ──

  describe "copy --from_repo parsing" do
    it "splits type:repo format correctly" do
      allow(directories).to receive(:copy)

      described_class.start(["copy", "user/bucket", "tokenizer", "models/tok",
                             "--from_repo", "dataset:org/my-data"])

      expect(directories).to have_received(:copy).with(
        "tokenizer", "models/tok",
        hash_including(source_type: "dataset", source_repo: "org/my-data")
      )
    end

    it "handles space type in --from_repo" do
      allow(directories).to receive(:copy)

      described_class.start(["copy", "user/bucket", "app", "spaces/app",
                             "--from_repo", "space:org/my-space"])

      expect(directories).to have_received(:copy).with(
        "app", "spaces/app",
        hash_including(source_type: "space", source_repo: "org/my-space")
      )
    end
  end

  # ── Phase 2: upload remote_path defaults ──

  describe "upload remote_path defaults" do
    it "uses basename of local_path when remote_path is omitted" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/tmp/model.bin").and_return(false)
      allow(files).to receive(:upload)

      described_class.start(["upload", "user/bucket", "/tmp/model.bin"])

      expect(files).to have_received(:upload).with("/tmp/model.bin", "model.bin")
    end
  end
end
