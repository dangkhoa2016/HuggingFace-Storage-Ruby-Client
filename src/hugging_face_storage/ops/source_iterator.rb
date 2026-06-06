# frozen_string_literal: true

require "set"

module HuggingFaceStorage
  # Iterates source configurations, classifies entries via {CopyPlanBuilder},
  # and filters already-existing files.
  # @api private
  # :nodoc:
  class SourceIterator
    # Creates a new source iterator.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the destination bucket ID
    # @param logger [Logger, nil] optional logger
    # @param debug_mode [Boolean] enable debug mode
    def initialize(api:, bucket_id:, logger: nil, debug_mode: false)
      @api = api
      @bucket_id = bucket_id
      @logger = logger || NullLogger.new
      @debug_mode = debug_mode
    end

    # Iterates over source configurations, classifies entries, and aggregates
    # copy operations, pending downloads, and per-source metadata.
    #
    # @param sources [Array] list of source configs
    # @yield [builder, source] block that processes each source via a {CopyPlanBuilder}
    # @yieldparam builder [CopyPlanBuilder] builder for the current source
    # @yieldparam source [Object] the source configuration
    # @yieldreturn [Hash] result with :copy_ops, :pending_downloads, :metadata, etc.
    # @return [Array<Array, Array, Array>] [all_copy_ops, all_pending_downloads, source_results]
    def iterate_and_classify(sources, &block)
      builder = CopyPlanBuilder.new(api: @api, bucket_id: @bucket_id, logger: @logger, debug_mode: @debug_mode)
      all_copy_ops = [] # : Array[Hash[Symbol, untyped]]
      all_pending_downloads = [] # : Array[Hash[Symbol, untyped]]
      source_results = [] # : Array[Hash[Symbol, untyped]]

      sources.each do |source|
        info = yield(builder, source)
        all_copy_ops.concat(info[:copy_ops])
        all_pending_downloads.concat(info[:pending_downloads])
        source_results << info[:metadata]

        @logger.info(
          "  Source: #{info[:file_count]} file(s), #{info[:directories].size} director(ies) — " \
          "#{info[:xet_count]} xet-copy, #{info[:download_count]} download"
        )
      end

      total_files = source_results.sum { |r| r[:file_count] }
      @logger.info("  Total: #{sources.size} source(s), #{total_files} file(s)")

      [all_copy_ops, all_pending_downloads, source_results]
    end

    # Wraps a {CopyPlanBuilder#process_source} result into the enriched hash
    # expected by the caller.
    #
    # @param result [Hash] raw result from {CopyPlanBuilder#process_source}
    # @param from [String] source description (for logging)
    # @param to [String, nil] destination description
    # @param source_base [String] source path base for metadata
    # @return [Hash] enriched result with :copy_ops, :pending_downloads, :metadata, etc.
    def wrap_source_result(result, from:, to:, source_base:)
      {
        copy_ops: result[:copy_ops],
        pending_downloads: result[:pending_downloads],
        file_count: result[:file_count],
        directories: result[:directories],
        xet_count: result[:xet_count],
        download_count: result[:download_count],
        metadata: {
          from: from, to: to,
          file_count: result[:file_count],
          directories: result[:directories],
          source_base: source_base,
          xet_count: result[:xet_count],
          download_count: result[:download_count]
        },
      }
    end

    # Filters out copy operations and pending downloads for files that already
    # exist at the destination.
    #
    # @param copy_ops [Array<Hash>] copy operations
    # @param pending_downloads [Array<Hash>] pending download operations
    # @param source_results [Array<Hash>] per-source metadata (for logging)
    # @return [Array] [filtered_copy_ops, filtered_pending_downloads, skipped_count]
    def skip_existing(copy_ops, pending_downloads, source_results)
      return [copy_ops, pending_downloads, 0] if copy_ops.empty? && pending_downloads.empty?

      existing = build_existing_set(copy_ops, pending_downloads)

      before_f = copy_ops.size + pending_downloads.size
      filtered_ops = copy_ops.reject { |op| file_exists?(op[:path], existing) }
      filtered_downloads = pending_downloads.reject { |dl| file_exists?(dl[:destination], existing) }
      skipped = before_f - (filtered_ops.size + filtered_downloads.size)

      log_skip_result(skipped, filtered_ops, filtered_downloads, source_results)

      [filtered_ops, filtered_downloads, skipped]
    end

    def log_skip_result(skipped, filtered_ops, filtered_downloads, source_results)
      return unless skipped.positive?

      @logger.info("  Skipped #{skipped} file(s) already exist at destination")
      return unless filtered_ops.empty? && filtered_downloads.empty?

      total_source_files = source_results.sum { |r| r[:file_count] }
      @logger.info("  Nothing to copy - all #{total_source_files} source file(s) already exist")
    end

    def build_existing_set(copy_ops, pending_downloads)
      candidate_paths = (copy_ops.map { |op| op[:path] } +
                        pending_downloads.map { |dl| dl[:destination] }).uniq
      candidate_paths.empty? ? Set.new : BucketQuery.batch_exists?(@api, @bucket_id, candidate_paths)
    end

    def file_exists?(path, existing)
      existing.include?(path)
    end
  end
end
