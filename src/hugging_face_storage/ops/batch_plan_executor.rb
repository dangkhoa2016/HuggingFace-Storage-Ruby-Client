# frozen_string_literal: true

module HuggingFaceStorage
  class CrossRepoCopyService
    # Executes a batch plan by coordinating existing-file filtering with the copy pipeline.
    class BatchPlanExecutor
      # @param api_client [ApiClient] the API client
      # @param source_iterator [SourceIterator] the source iterator
      # @param copy_pipeline [CopyPipeline] the copy pipeline
      # @param bucket_id [String] the destination bucket ID
      # @param logger [Logger] logger instance
      def initialize(api_client:, source_iterator:, copy_pipeline:, bucket_id:, logger:)
        @api = api_client
        @source_iterator = source_iterator
        @copy_pipeline = copy_pipeline
        @bucket_id = bucket_id
        @logger = logger
      end

      # Executes the batch plan by filtering existing files and running the copy pipeline.
      #
      # @param copy_ops [Array<Hash>] Xet copy operations
      # @param pending_downloads [Array<Hash>] files requiring download
      # @param source_results [Array<Hash>] source iteration results for skip logic
      # @param overwrite [Boolean] overwrite existing files
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @param label [String] log label
      # @param raise_on_partial_failure [Boolean] raise on partial failure
      # @return [Hash] result with :xet_copied, :files_downloaded, :total, :skipped_files, :skipped_dirs
      def call(copy_ops:, pending_downloads:, source_results:, overwrite:, cancel_token:,
               label:, raise_on_partial_failure: true)
        skipped_files = 0

        unless overwrite
          copy_ops, pending_downloads, skipped_files = @source_iterator.skip_existing(
            copy_ops, pending_downloads, source_results
          )
          if copy_ops.empty? && pending_downloads.empty?
            return { xet_copied: 0, files_downloaded: 0, total: 0,
                     skipped_files: skipped_files, skipped_dirs: 0 }
          end
        end

        total_files = copy_ops.size + pending_downloads.size

        plan = @copy_pipeline.execute(
          copy_ops: copy_ops, pending_downloads: pending_downloads,
          cancel_token: cancel_token, raise_on_partial_failure: raise_on_partial_failure
        )

        source_results.each do |r|
          @logger.info("  #{r[:from]} -> #{r[:to]}  (#{r[:file_count]} files)")
        end
        @logger.info(
          "#{label} complete: #{total_files} file(s) in #{plan[:elapsed_ms]}ms  " \
          "(xet: #{plan[:xet_copied]}, download: #{plan[:files_downloaded]}, skipped: #{skipped_files})"
        )

        { xet_copied: plan[:xet_copied], files_downloaded: plan[:files_downloaded],
          total: total_files, skipped_files: skipped_files, skipped_dirs: 0 }
      end
    end
  end
end
