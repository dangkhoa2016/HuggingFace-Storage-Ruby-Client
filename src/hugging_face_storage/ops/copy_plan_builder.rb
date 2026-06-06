# frozen_string_literal: true

require "json"

module HuggingFaceStorage
  # Builds a copy plan by enumerating source repo files and classifying entries.
  # @api private
  # :nodoc:
  class CopyPlanBuilder
    # Creates a new copy plan builder.
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

    # Processes a source repo/revision and builds copy/download operations.
    #
    # @param source_type [String] source type ("model", "dataset", or "bucket")
    # @param source_repo [String] source repository name
    # @param source_path [String, nil] optional sub-path within the source
    # @param revision [String] revision (branch, tag, or commit)
    # @param destination [String] destination path prefix
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param destination_mapper [Proc, nil] custom destination mapping
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [Hash] plan with :copy_ops, :pending_downloads, :lfs_offenders, etc.
    # @raise [NotFoundError] if source path not found
    # @raise [Error] if no files found
    def process_source(
      source_type:, source_repo:, destination:,
      source_path: nil, revision: "main", exclude: nil,
      destination_mapper: nil, cancel_token: nil
    )
      cancel_token&.raise_if_cancelled!

      source_base = source_path.to_s.empty? ? "" : source_path.to_s.sub(%r{/+\z}, "")
      mapper = destination_mapper || build_default_mapper(destination, source_base)

      result = fetch_and_classify_entries(source_type, source_repo, source_path, revision, mapper, exclude, @debug_mode)
      aggregate_copy_plan(result, source_base)
    end

    private

    # Lists files from a repo, wrapping NotFoundError with a detailed message.
    #
    # @param source_type [String] source type
    # @param source_repo [String] source repository name
    # @param source_path [String, nil] optional sub-path
    # @param effective_revision [String, nil] revision or nil for buckets
    # @param source_display [String] human-readable source path for error messages
    # @return [Array<Hash>] file entries
    # @raise [NotFoundError] if source path not found
    def list_repo_files(source_type, source_repo, source_path, effective_revision, source_display)
      @api.list_repo_files(
        source_type, source_repo,
        path: source_path.to_s.empty? ? nil : source_path,
        revision: effective_revision,
        recursive: true
      )
    rescue NotFoundError => e
      detail = begin
        JSON.parse(e.message.sub(/^Resource not found:\s*/, ""))["error"]
      rescue JSON::ParserError, TypeError
        e.message
      end
      ne = NotFoundError.new(
        "Source path '#{source_display}' not found in #{source_type} '#{source_repo}' " \
        "(revision: #{effective_revision || 'latest'}).\n  " \
        "#{detail}"
      )
      ne.set_backtrace(@debug_mode ? Array(e.backtrace) : [])
      raise ne, cause: e
    end

    # Removes files matching exclusion patterns from the list.
    #
    # @param files [Array<Hash>] file entries to filter
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @return [void]
    def apply_exclude(files, exclude)
      return unless exclude

      files.reject! { |e| ExcludeMatcher.match?(e[ResponseFields::PATH], exclude) }
    end

    # Lists repo files, applies exclusions, and classifies entries.
    #
    # @param source_type [String] source type
    # @param source_repo [String] source repository name
    # @param source_path [String, nil] optional sub-path
    # @param revision [String] revision
    # @param destination_mapper [Proc] destination mapping lambda
    # @param exclude [Array<String>, nil] glob patterns to exclude
    # @param debug_mode [Boolean] enable debug mode
    # @return [Hash] result with :classified, :files, :directories
    def fetch_and_classify_entries(source_type, source_repo, source_path, revision, destination_mapper, exclude,
                                   debug_mode)
      effective_revision = source_type == "bucket" ? nil : revision
      source_display = source_path.to_s.empty? ? "." : source_path.to_s

      entries = list_repo_files(source_type, source_repo, source_path, effective_revision, source_display)

      files = entries.select { |e| e[ResponseFields::TYPE] == ResponseFields::FILE_TYPE }
      directories = entries.select { |e| e[ResponseFields::TYPE] == ResponseFields::DIR_TYPE }

      apply_exclude(files, exclude)

      raise Error, "No files found in #{source_type}:#{source_repo}/#{source_display}" if files.empty?

      classified = EntryClassifier.classify(
        files,
        source_type: source_type,
        source_repo: source_repo,
        revision: effective_revision,
        debug_mode: debug_mode,
        path_infos: files,
        destination_mapper: destination_mapper
      )

      LfsGuard.new("#{source_type}:#{source_repo}/#{source_display}").check(classified[:lfs_offenders])

      {
        classified: classified,
        files: files,
        directories: directories,
      }
    end

    # Aggregates classified results into a copy plan hash.
    #
    # @param result [Hash] classified results with :classified, :files, :directories
    # @param source_base [String] source base path
    # @return [Hash] plan with :copy_ops, :pending_downloads, :file_count, etc.
    def aggregate_copy_plan(result, source_base)
      classified = result[:classified]
      files = result[:files]
      directories = result[:directories]

      {
        copy_ops: classified[:copy_ops],
        pending_downloads: classified[:pending_downloads],
        lfs_offenders: classified[:lfs_offenders],
        files: files,
        directories: directories,
        file_count: files.size,
        source_base: source_base,
        xet_count: classified[:copy_ops].size,
        download_count: classified[:pending_downloads].size,
      }
    end

    # Builds a default destination mapper lambda from destination prefix and source base.
    #
    # @param destination [String] destination path prefix
    # @param source_base [String] source base path to strip from entries
    # @return [Proc] mapper lambda
    def build_default_mapper(destination, source_base)
      lambda { |entry|
        src_path = entry[ResponseFields::PATH]
        rel_path = source_base.empty? ? src_path : src_path.sub(%r{^#{Regexp.escape(source_base)}/?}, "")
        "#{destination}/#{rel_path}"
      }
    end
  end
end
