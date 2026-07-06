# frozen_string_literal: true

require "set"

module HuggingFaceStorage
  # Utility methods for querying bucket file paths and metadata.
  module BucketQuery
    module_function

    # Queries path metadata from the API.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param paths [Array<String>] the paths to query
    # @return [Array<Hash>] path metadata results
    def query_paths(api, bucket_id, paths)
      r = api.post(ApiPaths.paths_info_path(bucket_id), body: { paths: paths })
      r.is_a?(Array) ? r : nil
    end

    # Fetches file info for a single path.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @return [Hash] file info with :path, :xet_hash, :size
    # @raise [NotFoundError] if the file is not found
    def fetch_file_info(api, bucket_id, path)
      results = query_paths(api, bucket_id, [path])
      raise NotFoundError, "File not found: #{path}" if results.nil? || results.empty?

      info = results.first
      { path: info[ResponseFields::PATH], xet_hash: info[ResponseFields::XET_HASH], size: info[ResponseFields::SIZE] }
    end

    # Checks whether a file exists at the given path.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @return [Boolean] true if the file exists
    def file_exists?(api, bucket_id, path)
      results = query_paths(api, bucket_id, [path])
      !results.nil? && !results.empty?
    rescue NotFoundError
      false
    end

    # Returns the set of existing file paths from a list.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param paths [Array<String>] the paths to check
    # @return [Set<String>] set of existing file paths
    def batch_exists?(api, bucket_id, paths)
      return Set.new if paths.empty?

      results = query_paths(api, bucket_id, paths)
      (results || []).select { |r| r[ResponseFields::TYPE] == ResponseFields::FILE_TYPE }.to_set { |r| r[ResponseFields::PATH] }
    end

    # Removes items whose paths already exist in the bucket.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param items [Array<Hash>] items with a path key
    # @param path_key [Symbol] the key for the path in each item
    # @return [Integer] number of items rejected
    def reject_existing!(api, bucket_id, items, path_key: :path)
      all_paths = items.map { |item| item[path_key] }
      existing = batch_exists?(api, bucket_id, all_paths)
      before = items.size
      items.reject! { |item| existing.include?(item[path_key]) }
      before - items.size
    end

    # Ensures a single file exists and is not a directory.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @raise [NotFoundError] if the file is not found
    # @raise [Error] if the path is a directory
    def ensure_file!(api, bucket_id, path)
      results = query_paths(api, bucket_id, [path])
      entry = results&.first
      raise NotFoundError, "File not found: #{path}" unless entry

      return unless entry[ResponseFields::TYPE] == ResponseFields::DIR_TYPE

      raise Error, "'#{path}' is a directory. Use client.directories.delete instead."
    end

    # Ensures multiple files exist and none are directories.
    #
    # @param api [ApiClient] the API client
    # @param bucket_id [String] the bucket identifier
    # @param paths [Array<String>] the file paths
    # @raise [NotFoundError] if any file is not found
    # @raise [Error] if any path is a directory
    def ensure_files!(api, bucket_id, paths)
      return ensure_file!(api, bucket_id, paths.first) if paths.one?

      results = query_paths(api, bucket_id, paths) || []

      dirs = results.select { |r| r[ResponseFields::TYPE] == ResponseFields::DIR_TYPE }
      if dirs.any?
        list = dirs.map { |d| "'#{d[ResponseFields::PATH]}'" }.join(", ")
        msg = dirs.one? ? "#{list} is a directory" : "#{list} are directories"
        raise Error, "#{msg}. Use client.directories.delete instead."
      end

      found = results.select { |r| r[ResponseFields::TYPE] == ResponseFields::FILE_TYPE }.map { |r| r[ResponseFields::PATH] }
      missing = paths - found
      raise NotFoundError, "File not found: #{missing.first}" if missing.any?
    end
  end
end
