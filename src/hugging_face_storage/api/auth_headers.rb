# frozen_string_literal: true

module HuggingFaceStorage
  class ApiClient
    # Builds and applies authentication headers for API requests.
    class AuthHeaders
      def initialize(auth:)
        @auth = auth
      end

      # Builds authentication and user-agent headers.
      #
      # @return [Hash{String => String}] header key-value pairs
      def call
        return {} unless @auth

        # @type var headers: Hash[String, String]
        headers = {}
        @auth.auth_header.each { |k, v| headers[k] = v }
        headers["User-Agent"] = "HuggingFaceStorage-Ruby/#{VERSION}"
        headers
      end

      # Applies authentication headers to a given HTTP request.
      #
      # @param request [Net::HTTPRequest] the request to modify
      # @return [void]
      def apply(request)
        call.each { |k, v| request[k] = v }
      end
    end
  end
end
