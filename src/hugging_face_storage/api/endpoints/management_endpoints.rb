# frozen_string_literal: true

module HuggingFaceStorage
  # @api private
  # :nodoc:
  module ManagementEndpoints
    # Fetches a Xet access token for a given bucket and type.
    #
    # @param bucket_id [String] the bucket identifier
    # @param type [String] token type ("read" or "write")
    # @return [Hash{Symbol => String, Integer, nil}] token info with :endpoint, :token, :expiration
    def get_xet_token(bucket_id, type)
      response = get(ApiPaths.xet_token_path(bucket_id, type)) # steep:ignore
      # @type var response: Hash[String, untyped]
      response = {} unless response.is_a?(Hash)
      {
        endpoint: response["casUrl"] || response["cas_url"] || response["endpoint"],
        token: response["accessToken"] || response["access_token"] || response["token"],
        expiration: response["exp"] || response["expiration"],
      }
    end

    # Fetches a write token for the given bucket.
    #
    # @param bucket_id [String] the bucket identifier
    # @return [Hash{Symbol => String, Integer, nil}] write token info
    def get_xet_write_token(bucket_id)
      get_xet_token(bucket_id, "write")
    end

    # Fetches a read token for the given bucket.
    #
    # @param bucket_id [String] the bucket identifier
    # @return [Hash{Symbol => String, Integer, nil}] read token info
    def get_xet_read_token(bucket_id)
      get_xet_token(bucket_id, "read")
    end
  end
end
