# frozen_string_literal: true

module HuggingFaceStorage
  module CliCommands
    # Snapshot and edit operations for the CLI.
    module Advanced
      # Downloads a directory snapshot with verification manifest.
      #
      # @param bucket [String] bucket identifier
      # @param remote_path [String] remote directory path
      # @param local_dir [String] local destination directory
      # @return [void]
      def snapshot(bucket, remote_path, local_dir)
        client = shared_client(bucket)
        result = client.directories.snapshot_download(remote_path, local_dir, verify: options[:verify])
        format_or_say({ action: "snapshot", files_downloaded: result[:files_downloaded],
                        manifest_path: result[:manifest_path] }) do
          say "Snapshot complete: #{result[:files_downloaded]} file(s), manifest: #{result[:manifest_path]}"
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      # Edits a remote file in-place with JSON edit operations.
      #
      # @param bucket [String] bucket identifier
      # @param remote_path [String] remote file path
      # @return [void]
      def edit(bucket, remote_path)
        client = shared_client(bucket)
        edits = JSON.parse(options[:edits])
        edits = edits.map { |e| e.transform_keys(&:to_sym) }
        client.files.edit(remote_path, edits: edits)
        format_or_say({ action: "edit", remote_path: remote_path, edits_count: edits.size }) do
          say "Edited: #{remote_path} (#{edits.size} edit(s) applied)"
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      rescue JSON::ParserError => e
        error CLIFormatter.format_error("Invalid --edits JSON: #{e.message}")
      end
    end
  end
end
