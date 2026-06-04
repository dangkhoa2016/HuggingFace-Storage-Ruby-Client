# frozen_string_literal: true

module HuggingFaceStorage
  # Handles file upload operations — single file, raw bytes, and glob-based uploads.
  class FileUploadService
    include Instrumentation

    # @param xet_uploader [XetUploader] the XET uploader
    # @param bucket_id [String] the bucket identifier
    # @param logger [Logger, nil] logger instance
    def initialize(xet_uploader:, bucket_id:, logger: nil, metrics_registry: nil, notifications: nil)
      @xet_uploader = xet_uploader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @metrics_registry = metrics_registry
      @notifications = notifications
    end

    # Upload a local file to the bucket.
    # @param local_path [String] path to the local file
    # @param remote_path [String] destination path in the bucket
    # @param on_progress [Proc, nil] called with +[uploaded_bytes, total_bytes]+
    # @param cancel_token [CancelToken, nil] cooperative cancellation
    # @param exclude [String, Array<String>, nil] glob pattern(s) to exclude
    # @return [Hash{Symbol => String}] +{ path:, local_path: }+
    def upload(local_path, remote_path, on_progress: nil, cancel_token: nil, exclude: nil)
      if exclude || glob?(local_path)
        return upload_glob(local_path, remote_path, on_progress: on_progress, cancel_token: cancel_token,
                                                    exclude: exclude)
      end

      raise Error, "Local file not found: #{local_path}" unless File.file?(local_path)

      @logger.info("Uploading file: #{local_path} -> #{remote_path}")
      cancel_token&.raise_if_cancelled!
      @xet_uploader.upload_file_to_path(@bucket_id, local_path, remote_path,
                                        on_progress: on_progress, cancel_token: cancel_token)
      @logger.info("Upload complete: #{remote_path}")
      @metrics_registry.increment(:files)
      @notifications.publish(:file_uploaded, path: remote_path, local_path: local_path)
      { path: remote_path, local_path: local_path }
    end

    # Upload raw bytes to the bucket.
    # @param data [String] binary data to upload
    # @param remote_path [String] destination path
    # @param on_progress [Proc, nil] progress callback
    # @param cancel_token [CancelToken, nil]
    # @return [Hash{Symbol => String, Integer}] +{ path:, size: }+
    def upload_bytes(data, remote_path, on_progress: nil, cancel_token: nil)
      @logger.info("Uploading #{data.bytesize} bytes -> #{remote_path}")
      cancel_token&.raise_if_cancelled!
      @xet_uploader.upload_bytes_to_path(@bucket_id, data, remote_path, on_progress: on_progress,
                                                                        cancel_token: cancel_token)
      @logger.info("Upload complete: #{remote_path} (#{data.bytesize} bytes)")
      @metrics_registry.increment(:files)
      @notifications.publish(:file_uploaded, path: remote_path, size: data.bytesize)
      { path: remote_path, size: data.bytesize }
    end

    private

    def glob?(path)
      path.to_s.match?(/[*?\[\]{}]/)
    end

    def upload_glob(pattern, remote_base, on_progress:, cancel_token:, exclude:)
      matches = Dir.glob(pattern).select { |f| File.file?(f) }
      matches.reject! { |f| ExcludeMatcher.match?(f, exclude) } if exclude
      raise Error, "No files match pattern: #{pattern}" if matches.empty?

      @logger.info("Uploading #{matches.size} file(s) from pattern: #{pattern}")
      # @type var results: Array[Hash[Symbol, String]]
      results = []
      matches.each do |f|
        cancel_token&.raise_if_cancelled!
        dest = remote_base.end_with?("/") ? "#{remote_base}#{File.basename(f)}" : remote_base
        @xet_uploader.upload_file_to_path(@bucket_id, f, dest, on_progress: on_progress, cancel_token: cancel_token)
        results << { path: dest, local_path: f }
      end
      results
    end
  end
end
