# frozen_string_literal: true

module HuggingFaceStorage
  module CliCommands
    # Copy operations for the CLI.
    module CopyCommands
      # Copies a file or directory within a bucket or across repos.
      #
      # @param bucket [String] bucket identifier
      # @param source [String] source path
      # @param dest [String] destination path
      # @return [void]
      def copy(bucket, source, dest)
        client = shared_client(bucket)
        if options[:from_repo]
          type, repo = options[:from_repo].split(":", 2)
          client.directories.copy(source, dest, source_type: type, source_repo: repo)
          format_or_say({ action: "copy", type: "cross_repo", source: source, dest: dest,
                          from_repo: options[:from_repo] }) do
            say "Cross-repo copy: #{options[:from_repo]}/#{source} -> #{dest}"
          end
        else
          client.directories.copy(source, dest)
          format_or_say({ action: "copy", type: "same_bucket", source: source, dest: dest }) do
            say "Copied: #{source} -> #{dest}"
          end
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end
    end
  end
end
