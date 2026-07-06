# frozen_string_literal: true

module HuggingFaceStorage
  class FileManager
    # Lists bucket files with optional prefix filtering and pagination.
    class Lister
      def initialize(api_client:, bucket_id:, logger:)
        @api = api_client
        @bucket_id = bucket_id
        @logger = logger
      end

      # Lists files in the bucket, optionally filtered by prefix.
      #
      # @param prefix [String, nil] path prefix to filter by
      # @param recursive [Boolean] list recursively
      # @param lazy [Boolean] return a lazy enumerator instead of an array
      # @return [Array<FileInfo>, Enumerator<FileInfo>] file info objects
      def list(prefix: nil, recursive: false, lazy: false)
        @logger.info("Listing files: prefix=#{prefix || 'root'} recursive=#{recursive} lazy=#{lazy}")
        entries = list_entries_with_pagination(prefix, recursive)

        if lazy
          Enumerator.new do |yielder|
            count = 0
            entries.each do |e|
              next unless e[ResponseFields::TYPE] == ResponseFields::FILE_TYPE

              yielder << FileInfo.new(
                path: e[ResponseFields::PATH], size: e[ResponseFields::SIZE],
                xet_hash: e[ResponseFields::XET_HASH], mtime: e[ResponseFields::MTIME]
              )
              count += 1
            end
            @logger.info("Lazy listing yielded #{count} file(s)")
          end
        else
          files = build_file_info_objects(entries)
          @logger.info("Found #{files.size} file(s)")
          files
        end
      end

      # Lists all files recursively with pagination support.
      #
      # @param prefix [String] path prefix to filter by
      # @param batch_size [Integer] page size
      # @param cancel_token [CancelToken, nil] cooperative cancellation token
      # @return [Array<Hash>] raw paginated API results
      def list_all(prefix:, batch_size: 1000, cancel_token: nil)
        @logger.info("Listing all files: prefix=#{prefix || 'root'} batch_size=#{batch_size}")
        path = ApiPaths.tree_path(@bucket_id)
        path += "/#{prefix}" if prefix
        @api.get_paginated(path, params: { recursive: "true" },
                                 cancel_token: cancel_token)
      end

      private

      # Fetches raw entries from the API with pagination.
      #
      # @param prefix [String, nil] path prefix
      # @param recursive [Boolean] list recursively
      # @return [Array<Hash>] raw API entries
      def list_entries_with_pagination(prefix, recursive)
        path = ApiPaths.tree_path(@bucket_id)
        path += "/#{prefix}" if prefix
        params = { recursive: recursive.to_s }
        @api.get_paginated(path, params: params)
      end

      # Filters entries to files and builds FileInfo objects.
      #
      # @param entries [Array<Hash>] raw API entries
      # @return [Array<FileInfo>] file info objects
      def build_file_info_objects(entries)
        entries.select { |e| e[ResponseFields::TYPE] == ResponseFields::FILE_TYPE }.map do |e|
          FileInfo.new(
            path: e[ResponseFields::PATH], size: e[ResponseFields::SIZE],
            xet_hash: e[ResponseFields::XET_HASH], mtime: e[ResponseFields::MTIME]
          )
        end
      end
    end
  end
end
