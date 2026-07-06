# frozen_string_literal: true

module HuggingFaceStorage
  # Constants for batch API operation types.
  module ApiOperations
    # @return [String] batch operation type for adding a file
    ADD_FILE = "addFile"
    # @return [String] batch operation type for deleting a file
    DELETE_FILE = "deleteFile"
    # @return [String] batch operation type for copying a file
    COPY_FILE  = "copyFile"
  end

  # API endpoint path constants and URL builder methods.
  module ApiPaths
    # @return [String] operator string for add-file API operations
    ADD_FILE = ApiOperations::ADD_FILE
    # @return [String] operator string for delete-file API operations
    DELETE_FILE = ApiOperations::DELETE_FILE
    # @return [String] operator string for copy-file API operations
    COPY_FILE = ApiOperations::COPY_FILE

    # @return [String] default HuggingFace API base URL
    BASE_URL = "https://huggingface.co"
    # @return [String] Content-Type header value for NDJSON
    CONTENT_TYPE_NDJSON = "application/x-ndjson"
    # @return [String] Content-Type header value for JSON
    CONTENT_TYPE_JSON = "application/json"
    # @return [String] Content-Type header value for octet streams
    CONTENT_TYPE_OCTET = "application/octet-stream"

    # @return [Array<Integer>] HTTP status codes eligible for retry
    RETRYABLE_HTTP_STATUSES = [429, 500, 502, 503, 504].freeze
    # @return [Array<Integer>] HTTP redirect status codes
    REDIRECT_CODES = [301, 302, 307, 308].freeze

    # HTTP status code ranges for classifying API responses.
    module Status
      # @return [Range<Integer>] successful HTTP status range
      OK = 200..299
      # @return [Integer] HTTP 401 Unauthorized
      UNAUTHORIZED = 401
      # @return [Integer] HTTP 403 Forbidden
      FORBIDDEN = 403
      # @return [Integer] HTTP 404 Not Found
      NOT_FOUND = 404
      # @return [Integer] HTTP 409 Conflict
      CONFLICT = 409
      # @return [Integer] HTTP 422 Unprocessable Entity
      UNPROCESSABLE = 422
      # @return [Integer] HTTP 429 Too Many Requests
      TOO_MANY_REQUESTS = 429
      # @return [Range<Integer>] HTTP 5xx server error range
      SERVER_ERRORS = 500..599
    end

    # Builds a URL path for a bucket resource.
    #
    # @param bucket_id [String] the bucket identifier
    # @param parts [Array<String>] path segments to append
    # @return [String] the constructed API path
    def self.bucket_path(bucket_id, *parts)
      "/api/buckets/#{bucket_id}/#{parts.join('/')}"
    end

    # Builds the URL path for a Xet token endpoint.
    #
    # @param bucket_id [String] the bucket identifier
    # @param type [String] token type (e.g. "read", "write")
    # @return [String] the token endpoint path
    def self.xet_token_path(bucket_id, type)
      "/api/buckets/#{bucket_id}/xet-#{type}-token"
    end

    # Builds the URL path for the paths-info endpoint.
    #
    # @param bucket_id [String] the bucket identifier
    # @return [String] the paths-info endpoint path
    def self.paths_info_path(bucket_id)
      bucket_path(bucket_id, "paths-info")
    end

    # Builds the URL path for the tree endpoint.
    #
    # @param bucket_id [String] the bucket identifier
    # @param path [String, nil] optional sub-path within the tree
    # @return [String] the tree endpoint path
    def self.tree_path(bucket_id, path = nil)
      if path
        "/api/buckets/#{bucket_id}/tree/#{path}"
      else
        "/api/buckets/#{bucket_id}/tree"
      end
    end

    # Builds the URL path for the batch endpoint.
    #
    # @param bucket_id [String] the bucket identifier
    # @return [String] the batch endpoint path
    def self.batch_path(bucket_id)
      bucket_path(bucket_id, "batch")
    end

    # Builds the URL path for a repository tree endpoint.
    #
    # @param repo_type [String] repository type (e.g. "model", "dataset")
    # @param repo_name [String] repository name
    # @return [String] the repo tree endpoint path
    def self.repo_tree_path(repo_type, repo_name)
      "/api/#{repo_type}s/#{repo_name}/tree"
    end

    # Builds the URL path for a repository paths-info endpoint.
    #
    # @param repo_type [String] repository type (e.g. "model", "dataset")
    # @param repo_name [String] repository name
    # @return [String] the repo paths-info endpoint path
    def self.repo_paths_info_path(repo_type, repo_name)
      "/api/#{repo_type}s/#{repo_name}/paths-info"
    end

    # Builds the URL path for resolving (downloading) a file in a bucket.
    #
    # @param bucket_id [String] the bucket identifier
    # @param path [String] the file path
    # @return [String] the resolve endpoint path
    def self.resolve_path(bucket_id, path)
      "/buckets/#{bucket_id}/resolve/#{Paths.encode_segments(path)}"
    end

    # Builds the URL path for the bucket listing endpoint in a namespace.
    #
    # @param namespace [String] the namespace
    # @return [String] the buckets list endpoint path
    def self.buckets_path(namespace)
      "/api/buckets/#{namespace}"
    end

    # Builds the URL path for bucket metadata.
    #
    # @param bucket_id [String] the bucket identifier
    # @return [String] the bucket info endpoint path
    def self.bucket_info_path(bucket_id)
      "/api/buckets/#{bucket_id}"
    end
  end
end
