# frozen_string_literal: true

module HuggingFaceStorage
  # CLI command implementations shared across subcommands.
  module CliCommands
    # Delete, move, list, and info operations for the CLI.
    module Manage
      # Deletes a file or directory from a bucket with confirmation.
      #
      # @param bucket [String] bucket identifier
      # @param path [String] path to delete
      # @return [void]
      def delete(bucket, path)
        unless options[:force]
          msg = "Are you sure you want to delete #{path} from #{bucket}?"
          answer = ask(msg, limited_to: %w[y Y yes Yes n N no No])
          return unless answer.match?(/\A[Yy]/)
        end

        client = shared_client(bucket)
        if client.files.exists?(path)
          client.files.delete(path)
          format_or_say({ action: "delete", type: "file", path: path }) do
            say "Deleted file: #{path}"
          end
        else
          client.directories.delete(path, recursive: options[:recursive])
          format_or_say({ action: "delete", type: "directory", path: path }) do
            say "Deleted directory: #{path}"
          end
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      # Moves a file or directory within a bucket.
      #
      # @param bucket [String] bucket identifier
      # @param source [String] source path
      # @param dest [String] destination path
      # @return [void]
      def move(bucket, source, dest)
        client = shared_client(bucket)
        if client.files.exists?(source)
          client.files.move(source, dest)
        else
          client.directories.move(source, dest)
        end
        format_or_say({ action: "move", source: source, dest: dest }) do
          say "Moved: #{source} -> #{dest}"
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      # Lists files in a bucket, optionally filtered by prefix.
      #
      # @param bucket [String] bucket identifier
      # @param path [String, nil] optional path prefix
      # @return [void]
      def list(bucket, path = nil)
        client = shared_client(bucket)
        files = client.files.list(prefix: path, recursive: options[:recursive])
        if files.empty?
          say "No files found"
        else
          rows = files.map { |f| [f.path, f.size, f.xet_hash&.slice(0, 12), f.mtime] }
          CLIFormatter.format_output(rows, options[:json] ? "json" : options[:format],
                                     headers: %w[path size xet_hash mtime])
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      # Shows metadata for a bucket, file, or directory.
      #
      # @param bucket [String] bucket identifier
      # @param path [String, nil] optional file or directory path
      # @return [void]
      def info(bucket, path = nil)
        client = shared_client(bucket)
        if path.nil?
          say CLIFormatter.format_json(client.bucket_info)
        elsif client.files.exists?(path)
          say CLIFormatter.format_json(client.files.metadata(path).to_h)
        else
          say CLIFormatter.format_json(client.directories.metadata(path).to_h)
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end
    end
  end
end
