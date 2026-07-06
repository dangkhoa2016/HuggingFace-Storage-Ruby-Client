# frozen_string_literal: true

module HuggingFaceStorage
  # Uploads local directories to a remote bucket.
  # @api private
  # :nodoc:
  class DirectoryUploader
    # Creates a new directory uploader.
    #
    # @param api_client [ApiClient] the API client
    # @param xet_uploader [XetUploader] the Xet uploader
    # @param bucket_id [String] the bucket identifier
    # @param logger [Logger, nil] optional logger
    # @param config [Configuration, nil] optional configuration
    def initialize(api_client:, xet_uploader:, bucket_id:, logger: nil, config: nil)
      @api = api_client
      @xet_uploader = xet_uploader
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @config = config || Configuration.default
    end

    # Uploads a local directory to a remote bucket path.
    #
    # @param local_dir [String] the local directory path
    # @param remote_base [String] the remote base path
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] result with :directory, :files_uploaded, :total_size
    def upload(local_dir, remote_base, exclude: nil, cancel_token: nil)
      all_files = LocalFileCollector.collect(local_dir, exclude)
      raise Error, "No files found in directory: #{local_dir}" if all_files.empty?

      # @type var file_stats: Array[[String, Integer]]
      file_stats = all_files.map { |f| [f, File.stat(f).size] }
      classification = classify_files(file_stats)
      execute_upload_flow(local_dir, remote_base, all_files, classification, cancel_token)
    end

    private

    def classify_files(file_stats)
      total_size = 0
      large_files = []
      small_files = []

      file_stats.each do |f, size|
        total_size += size
        if size > @config.batch_threshold
          large_files << [f, size]
        else
          small_files << [f, size]
        end
      end

      { large_files: large_files, small_files: small_files, total_size: total_size }
    end

    module UploadExecution
      def execute_upload_flow(local_dir, remote_base, all_files, classification, cancel_token)
        @logger.info(
          "Uploading directory: #{local_dir} -> #{remote_base} " \
          "(#{all_files.size} files, #{Utils.human_size(classification[:total_size])})"
        )
        if classification[:large_files].any?
          @logger.info(
            "  Small files (batch): #{classification[:small_files].size}, " \
            "Large files (individual): #{classification[:large_files].size}"
          )
        end

        uploaded = 0
        total = all_files.size

        unless classification[:small_files].empty?
          cancel_token&.raise_if_cancelled!
          batches = build_batches(classification[:small_files])
          uploaded = upload_small_batches(batches, local_dir, remote_base, cancel_token, total)
        end

        upload_large_files(classification[:large_files], local_dir, remote_base, cancel_token, uploaded, total)

        @logger.info("Directory upload complete: #{total} files, #{Utils.human_size(classification[:total_size])}")
        { directory: remote_base, files_uploaded: total, total_size: classification[:total_size] }
      end

      def build_batches(small_files)
        batches = []
        current_batch = []
        current_size = 0

        small_files.each do |f, size|
          if current_size + size > @config.batch_memory_limit && !current_batch.empty?
            batches << current_batch
            current_batch = []
            current_size = 0
          end
          current_batch << [f, size]
          current_size += size
        end
        batches << current_batch unless current_batch.empty?
        batches
      end

      def upload_small_batches(batches, local_dir, remote_base, cancel_token, total)
        uploaded = 0

        batches.each do |batch|
          batch_entries = batch.map do |f, size|
            relative = f.sub("#{local_dir}/", "")
            { local_path: f, remote_path: "#{remote_base}/#{relative}", size: size }
          end

          progress_handler = proc { |_i, path, _size|
            relative = path.sub("#{remote_base}/", "")
            uploaded += 1
            if uploaded == 1 || uploaded == total ||
               (uploaded % 10).zero?
              @logger.info("  [#{uploaded}/#{total}] #{relative}")
            end
          }

          @xet_uploader.upload_batch(@bucket_id, batch_entries, cancel_token: cancel_token,
                                                                on_progress: progress_handler)
        end

        uploaded
      end

      def upload_large_files(large_files, local_dir, remote_base, cancel_token, uploaded_so_far, total)
        large_files.each do |f, size|
          cancel_token&.raise_if_cancelled!
          relative = f.sub("#{local_dir}/", "")
          target = "#{remote_base}/#{relative}"
          uploaded_so_far += 1
          @logger.info("  [#{uploaded_so_far}/#{total}] #{relative} (#{Utils.human_size(size)}) [individual]")
          @xet_uploader.upload_file_to_path(@bucket_id, f, target, cancel_token: cancel_token,
                                                                   on_progress: proc { |_path, current, max|
                                                                     pct = (current * 100 / max).to_i
                                                                     @logger.debug do
                                                                       format(
                                                                         "    %s: %s/%s (%d%%)",
                                                                         relative,
                                                                         Utils.human_size(current),
                                                                         Utils.human_size(max),
                                                                         pct
                                                                       )
                                                                     end
                                                                   })
        end
      end
    end

    include UploadExecution
  end
end
