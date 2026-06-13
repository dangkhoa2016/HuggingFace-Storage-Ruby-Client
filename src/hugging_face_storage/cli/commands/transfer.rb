# frozen_string_literal: true

module HuggingFaceStorage
  module CliCommands
    # Upload and download operations for the CLI.
    module Transfer
      # Uploads a file, glob, or directory to a bucket.
      #
      # @param bucket [String] bucket identifier
      # @param local_path [String] local file, glob pattern, or directory path
      # @param remote_path [String, nil] optional remote path
      # @return [void]
      def upload(bucket, local_path, remote_path = nil)
        client = shared_client(bucket)
        remote_path ||= File.basename(local_path)

        if File.directory?(local_path)
          upload_directory(client, local_path, remote_path)
        elsif local_path.match?(/[*?\[\]{}]/)
          upload_glob(client, local_path, remote_path)
        else
          upload_file(client, local_path, remote_path)
        end
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      # Downloads a file or directory from a bucket.
      #
      # @param bucket [String] bucket identifier
      # @param remote_path [String] remote path
      # @param local_path [String] local destination path
      # @return [void]
      def download(bucket, remote_path, local_path)
        client = shared_client(bucket)
        if client.files.exists?(remote_path)
          client.files.download(remote_path, local_path)
          format_or_say({ action: "download", type: "file", remote_path: remote_path,
                          local_path: local_path }) do
            say "Downloaded file: #{remote_path} -> #{local_path}"
          end
        elsif client.directories.exists?(remote_path)
          client.directories.download(remote_path, local_path, parallel: options[:parallel])
          format_or_say({ action: "download", type: "directory", remote_path: remote_path,
                          local_path: local_path }) do
            say "Downloaded directory: #{remote_path} -> #{local_path}"
          end
        else
          raise Thor::Error, "Not found: #{remote_path}"
        end
      rescue HuggingFaceStorage::NotFoundError => e
        error CLIFormatter.format_error(e.message, hint: "Check the path and try again")
      rescue HuggingFaceStorage::Error => e
        error CLIFormatter.format_error(e.message)
      end

      private

      def upload_directory(client, local_path, remote_path)
        result = client.directories.upload(local_path, remote_path, exclude: options[:exclude])
        format_or_say({ action: "upload", type: "directory", files_uploaded: result[:files_uploaded],
                        local_path: local_path, remote_path: remote_path }) do
          say "Uploaded directory: #{result[:files_uploaded]} file(s)"
        end
      end

      def upload_glob(client, local_path, remote_path)
        result = client.files.upload(local_path, remote_path, exclude: options[:exclude])
        format_or_say({ action: "upload", type: "glob", files_uploaded: Array(result).size,
                        local_path: local_path, remote_path: remote_path }) do
          say "Uploaded #{Array(result).size} file(s) matching pattern"
        end
      end

      def upload_file(client, local_path, remote_path)
        client.files.upload(local_path, remote_path)
        format_or_say({ action: "upload", type: "file", local_path: local_path,
                        remote_path: remote_path }) do
          say "Uploaded: #{local_path} -> #{remote_path}"
        end
      end
    end
  end
end
