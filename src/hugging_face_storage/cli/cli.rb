# frozen_string_literal: true

require "thor"

# Inline stubs for CLI dependencies — replaced by real versions in commit 61
module HuggingFaceStorage
  module CliCommands
    module Transfer
      def upload(bucket, local_path, remote_path = nil); end
      def download(bucket, remote_path, local_path); end
    end

    module Manage
      def delete(bucket, path); end
      def move(bucket, source, dest); end
      def list(bucket, path = nil); end
      def info(bucket, path = nil); end
    end

    module CopyCommands
      def copy(bucket, source, dest); end
    end

    module Advanced
      def snapshot(bucket, remote_path, local_dir); end
      def edit(bucket, remote_path); end
    end
  end

  class BucketsCLI < Thor
  end
end

module HuggingFaceStorage
  # Main Thor CLI for HuggingFace storage operations.
  class CLI < Thor
    class_option :token, type: :string, desc: "HuggingFace token (or HF_TOKEN env)"
    class_option :format, type: :string, default: "text", enum: %w[text json],
                          desc: "Output format (text or json)"
    class_option :json, type: :boolean, desc: "Output in JSON format"

    include CliCommands::Transfer
    include CliCommands::Manage
    include CliCommands::CopyCommands
    include CliCommands::Advanced

    BUCKET_PATTERN = %r{\A[\w-]+/[\w.-]+\z}

    no_commands do
      def shared_client(bucket)
        unless BUCKET_PATTERN.match?(bucket)
          raise ArgumentError,
                "Invalid bucket format: '#{bucket}' — expected namespace/bucket (e.g. user/my-bucket)"
        end
        @shared_client ||= {}
        @shared_client[bucket] ||= CLIFormatter.build_client(bucket, token: options[:token])
      end

      def format_or_say(result)
        if options[:json] || options[:format] == "json"
          say CLIFormatter.format_json(result)
        else
          yield
        end
      end
    end

    desc "upload BUCKET LOCAL_PATH [REMOTE_PATH]", "Upload file or directory"
    option :exclude, type: :string, repeatable: true
    option :parallel, type: :numeric, default: 4
    def upload(bucket, local_path, remote_path = nil)
      dispatch(:upload, CliCommands::Transfer, bucket, local_path, remote_path)
    end

    desc "download BUCKET REMOTE_PATH LOCAL_PATH", "Download file or directory"
    option :parallel, type: :numeric, default: 4
    def download(bucket, remote_path, local_path)
      dispatch(:download, CliCommands::Transfer, bucket, remote_path, local_path)
    end

    desc "copy BUCKET SOURCE DEST", "Copy file or directory"
    option :from_repo, type: :string, desc: "Source repo (type/name, e.g., model:user/model)"
    option :source_type, type: :string, default: "bucket"
    def copy(bucket, source, dest)
      dispatch(:copy, CliCommands::CopyCommands, bucket, source, dest)
    end

    desc "delete BUCKET PATH", "Delete file or directory"
    option :recursive, type: :boolean, default: true, aliases: "-r"
    option :force, type: :boolean, default: false, aliases: "-f",
                   desc: "Skip confirmation prompt"
    def delete(bucket, path)
      dispatch(:delete, CliCommands::Manage, bucket, path)
    end

    desc "move BUCKET SOURCE DEST", "Move file or directory"
    def move(bucket, source, dest)
      dispatch(:move, CliCommands::Manage, bucket, source, dest)
    end

    desc "list BUCKET [PATH]", "List files"
    option :recursive, type: :boolean, default: false, aliases: "-r"
    option :format, type: :string, default: "table", enum: %w[table json]
    def list(bucket, path = nil)
      dispatch(:list, CliCommands::Manage, bucket, path)
    end

    desc "info BUCKET [PATH]", "Show metadata"
    def info(bucket, path = nil)
      dispatch(:info, CliCommands::Manage, bucket, path)
    end

    desc "snapshot BUCKET REMOTE_PATH LOCAL_DIR", "Download directory snapshot with manifest"
    option :verify, type: :boolean, default: false
    def snapshot(bucket, remote_path, local_dir)
      dispatch(:snapshot, CliCommands::Advanced, bucket, remote_path, local_dir)
    end

    desc "edit BUCKET REMOTE_PATH", "Edit a remote file in-place"
    option :edits, type: :string, required: true, desc: "JSON array of edits"
    def edit(bucket, remote_path)
      dispatch(:edit, CliCommands::Advanced, bucket, remote_path)
    end

    desc "buckets SUBCOMMAND", "Bucket operations"
    subcommand "buckets", BucketsCLI

    private

    def dispatch(method_name, mod, *args)
      mod.instance_method(method_name).bind_call(self, *args)
    end
  end
end
