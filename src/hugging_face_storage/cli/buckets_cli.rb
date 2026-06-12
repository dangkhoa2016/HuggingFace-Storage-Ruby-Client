# frozen_string_literal: true

module HuggingFaceStorage
  # Thor CLI subcommand for bucket-level operations (list, info).
  class BucketsCLI < Thor
    namespace "buckets"

    desc "list [NAMESPACE]", "List buckets (optionally filter by namespace)"
    def list(namespace = nil)
      ns = namespace || ENV.fetch("HF_NAMESPACE", nil)
      raise Thor::Error, "NAMESPACE required (or set HF_NAMESPACE)" unless ns

      client = HuggingFaceStorage.new(token: ENV.fetch("HF_TOKEN", nil), namespace: ns, bucket: "_", log_level: :warn)
      result = client.list_buckets
      say CLIFormatter.format_table(result.map { |b| [b["name"], b["createdAt"], b["id"]] }, %w[name createdAt id])
    end

    desc "info BUCKET", "Show bucket info"
    # @param bucket [String] bucket identifier
    # @return [void]
    def info(bucket)
      client = CLIFormatter.build_client(bucket)
      info = client.bucket_info
      say CLIFormatter.format_json(info)
    end
  end
end
