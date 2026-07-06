# frozen_string_literal: true

module HuggingFaceStorage
  class CrossRepoCopyService
    # Handles repo-level copy operations by iterating over sources and classifying entries.
    class RepoCopyStrategy
      # @param api_client [ApiClient] the API client
      # @param source_iterator [SourceIterator] the source iterator
      # @param logger [Logger] logger instance
      def initialize(api_client:, source_iterator:, logger:)
        @api = api_client
        @source_iterator = source_iterator
        @logger = logger
      end

      # Processes repo source paths and builds copy/download operations.
      #
      # @param sources [Array<String, nil>] source paths to copy
      # @param normalized_dst_base [String, nil] normalized destination base
      # @param source_type [String] source type
      # @param source_repo [String] source repository name
      # @param revision [String] revision
      # @param exclude [Array<String>, nil] glob patterns to exclude
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @return [Hash] result with :copy_ops, :pending_downloads, :results
      def call(sources:, normalized_dst_base:, source_type:, source_repo:, revision:,
               exclude:, cancel_token:)
        effective_revision = source_type == "bucket" ? nil : revision
        @logger.info("Cross-repo copy: #{source_type}:#{source_repo}@#{effective_revision || 'n/a'}")

        sources = Array(sources) unless sources.is_a?(Array)
        all_copy_ops, all_pending_downloads, all_results = execute_source_iteration(
          sources, normalized_dst_base, source_type, source_repo, revision, exclude, cancel_token
        )

        { copy_ops: all_copy_ops, pending_downloads: all_pending_downloads, results: all_results }
      end

      private

      # Iterates over sources and classifies entries via SourceIterator.
      #
      # @param sources [Array<String, nil>] source paths
      # @param normalized_dst_base [String, nil] normalized destination base
      # @param source_type [String] source type ("model", "dataset", or "bucket")
      # @param source_repo [String] source repository name
      # @param revision [String] revision
      # @param exclude [Array<String>, nil] glob patterns to exclude
      # @param cancel_token [CancelToken, nil] optional cancellation token
      # @return [Array] tuple of [all_copy_ops, all_pending_downloads, all_results]
      def execute_source_iteration(sources, normalized_dst_base, source_type, source_repo, revision,
                                   exclude, cancel_token)
        @source_iterator.iterate_and_classify(sources) do |builder, src|
          dst = if sources.size > 1 && normalized_dst_base
                  "#{normalized_dst_base}/#{File.basename(Paths.normalize(src))}"
                else
                  normalized_dst_base
                end
          source_base = src.to_s.sub(%r{/+\z}, "")

          result = builder.process_source(
            source_type: source_type, source_repo: source_repo,
            source_path: src.to_s.empty? ? nil : src,
            revision: revision, destination: dst, exclude: exclude,
            destination_mapper: lambda { |entry|
              src_path = entry[ResponseFields::PATH]
              rel_path = source_base.empty? ? src_path : src_path.sub(%r{^#{Regexp.escape(source_base)}/?}, "")
              dst ? "#{dst}/#{rel_path}" : rel_path
            },
            cancel_token: cancel_token
          )

          @source_iterator.wrap_source_result(result, from: src, to: dst, source_base: source_base)
        end
      end
    end
  end
end
