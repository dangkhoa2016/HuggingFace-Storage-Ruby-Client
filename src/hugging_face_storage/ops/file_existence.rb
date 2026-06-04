# frozen_string_literal: true

require "json"

module HuggingFaceStorage
  # Checks file existence via HEAD requests with fallback to listing.
  # @api private
  # :nodoc:
  class FileExistence
    # Initializes a new FileExistence checker.
    #
    # @param transport [HTTPTransport] the HTTP transport
    # @param logger [Logger] the logger instance
    def initialize(transport:, logger:)
      @transport = transport
      @logger = logger
    end

    # Checks whether a file exists by issuing a HEAD request, falling back
    # to listing the parent directory on 404.
    #
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @return [Boolean] true if the file exists
    def file_exists?(bucket_id, path)
      @transport.request(:head, ApiPaths.resolve_path(bucket_id, path))
      true
    rescue NotFoundError
      false
    rescue ApiError
      dir_path = Paths.parent(path)
      list_files(bucket_id, prefix: dir_path).any? { |f| f[ResponseFields::PATH] == path }
    end

    # Lists files in a bucket, paginating through all entries.
    #
    # @param bucket_id [String] the bucket identifier
    # @param prefix [String] path prefix to filter by (default "")
    # @param recursive [Boolean] list recursively (default true)
    # @return [Array<Hash>] list of file entries
    def list_files(bucket_id, prefix: "", recursive: true)
      # @type var items: Array[Hash[String, untyped]]
      items = []
      after = nil

      loop do
        query = if after
                  { prefix: prefix, recursive: recursive,
                    after: after }
                else
                  { prefix: prefix, recursive: recursive }
                end

        data = @transport.request(:get, "/api/buckets/#{bucket_id}/paths", query: query)
        entries = JSON.parse(data)

        items.concat(entries.select { |entry| entry[ResponseFields::TYPE] == ResponseFields::FILE_TYPE })

        break unless entries.last&.dig(ResponseFields::PATH)

        after = entries.last[ResponseFields::PATH]
      end

      items
    end
  end
end
