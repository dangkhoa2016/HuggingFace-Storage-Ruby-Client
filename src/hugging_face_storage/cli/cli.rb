# frozen_string_literal: true

require "thor"
require_relative "formatter"
require_relative "commands/transfer"
require_relative "commands/manage"
require_relative "commands/copy_commands"
require_relative "commands/advanced"
require_relative "buckets_cli"

module HuggingFaceStorage
  # Main Thor CLI for HuggingFace storage operations.
  class CLI < Thor
    class_option :token, type: :string, desc: "HuggingFace token (or HF_TOKEN env)"
    class_option :format, type: :string, default: "text", enum: %w[text json],
                          desc: "Output format (text or json)"
    class_option :json, type: :boolean, desc: "Output in JSON format"
    class_option :log_level, type: :string, default: "warn",
                             enum: %w[debug info warn error],
                             desc: "Log verbosity (default: warn)"

    # ── Command implementations ──────────────────────────────────────
    # NOTE: Modules define the actual logic; CLI methods explicitly dispatch
    # via UnboundMethod#bind_call rather than relying on `super` include-order
    # resolution, making dispatch order unambiguous.
    include CliCommands::Transfer
    include CliCommands::Manage
    include CliCommands::CopyCommands
    include CliCommands::Advanced

    BUCKET_PATTERN = %r{\A[\w-]+/[\w.-]+\z}.freeze

    no_commands do
      def shared_client(bucket)
        unless BUCKET_PATTERN.match?(bucket)
          raise ArgumentError,
                "Invalid bucket format: '#{bucket}' — expected namespace/bucket (e.g. user/my-bucket)"
        end

        # @type var client: Hash[String, Client]
        client = {}
        @shared_client ||= client
        @shared_client[bucket] ||= CLIFormatter.build_client(
          bucket, token: options[:token], log_level: options[:log_level]
        )
      end

      def format_or_say(result)
        if options[:json] || options[:format] == "json"
          say CLIFormatter.format_json(result)
        else
          yield
        end
      end
    end

    # ── Upload ───────────────────────────────────────────────────────
    desc "upload BUCKET LOCAL_PATH [REMOTE_PATH]", "Upload file or directory"
    option :exclude, type: :string, repeatable: true
    option :parallel, type: :numeric, default: 4
    def upload(bucket, local_path, remote_path = nil)
      dispatch(:upload, CliCommands::Transfer, bucket, local_path, remote_path)
    end

    # ── Download ─────────────────────────────────────────────────────
    desc "download BUCKET REMOTE_PATH LOCAL_PATH", "Download file or directory"
    option :parallel, type: :numeric, default: 4
    def download(bucket, remote_path, local_path)
      dispatch(:download, CliCommands::Transfer, bucket, remote_path, local_path)
    end

    # ── Copy ─────────────────────────────────────────────────────────
    desc "copy BUCKET SOURCE DEST", "Copy file or directory"
    option :from_repo, type: :string, desc: "Source repo (type/name, e.g., model:user/model)"
    option :source_type, type: :string, default: "bucket"
    def copy(bucket, source, dest)
      dispatch(:copy, CliCommands::CopyCommands, bucket, source, dest)
    end

    # ── Delete ───────────────────────────────────────────────────────
    desc "delete BUCKET PATH", "Delete file or directory"
    option :recursive, type: :boolean, default: true, aliases: "-r"
    option :force, type: :boolean, default: false, aliases: "-f",
                   desc: "Skip confirmation prompt"
    long_desc <<~LONGDESC
      Delete a file or directory from a bucket.

      By default, prompts for confirmation before deleting. Use --force to skip.

      Examples:

        $ hfs delete user/my-bucket old-model.pt
        $ hfs delete user/my-bucket temp-dir --force
    LONGDESC
    def delete(bucket, path)
      dispatch(:delete, CliCommands::Manage, bucket, path)
    end

    # ── Move ─────────────────────────────────────────────────────────
    desc "move BUCKET SOURCE DEST", "Move file or directory"
    def move(bucket, source, dest)
      dispatch(:move, CliCommands::Manage, bucket, source, dest)
    end

    # ── List ─────────────────────────────────────────────────────────
    desc "list BUCKET [PATH]", "List files"
    option :recursive, type: :boolean, default: false, aliases: "-r"
    option :format, type: :string, default: "table", enum: %w[table json]
    def list(bucket, path = nil)
      dispatch(:list, CliCommands::Manage, bucket, path)
    end

    # ── Info ─────────────────────────────────────────────────────────
    desc "info BUCKET [PATH]", "Show metadata"
    def info(bucket, path = nil)
      dispatch(:info, CliCommands::Manage, bucket, path)
    end

    # ── Snapshot ─────────────────────────────────────────────────────
    desc "snapshot BUCKET REMOTE_PATH LOCAL_DIR", "Download directory snapshot with manifest"
    option :verify, type: :boolean, default: false
    def snapshot(bucket, remote_path, local_dir)
      dispatch(:snapshot, CliCommands::Advanced, bucket, remote_path, local_dir)
    end

    # ── Edit ─────────────────────────────────────────────────────────
    desc "edit BUCKET REMOTE_PATH", "Edit a remote file in-place"
    option :edits, type: :string, required: true,
                   desc: "JSON array of edits"
    long_desc <<~LONGDESC
      Edit a remote file without download/upload cycle.

      Edits are specified as a JSON array of edit operations. Each operation must have:
        type  - "replace" (find/replace by strings) or "patch" (byte offsets)
        old   - the text to find (for replace type)
        new   - the replacement text (for replace type)

      Example:

        $ hfs edit user/my-bucket config.json \
            --edits '[{"type":"replace","old":"\\"version\\": 1","new":"\\"version\\": 2"}]'
    LONGDESC
    def edit(bucket, remote_path)
      dispatch(:edit, CliCommands::Advanced, bucket, remote_path)
    end

    # ── Subcommand ──────────────────────────────────────────────────
    desc "buckets SUBCOMMAND", "Bucket operations"
    subcommand "buckets", BucketsCLI

    private

    # Dispatches a CLI command to a specific module's implementation.
    #
    # Uses +UnboundMethod#bind_call+ to invoke the method from the named
    # module directly, bypassing Ruby's MRO. This ensures the correct
    # implementation runs regardless of include order.
    #
    # @param method_name [Symbol] the method to call
    # @param mod [Module] the module defining the implementation
    # @param args [Array] arguments forwarded to the method
    # @return [void]
    def dispatch(method_name, mod, *args)
      mod.instance_method(method_name).bind_call(self, *args)
    end
  end
end
