# frozen_string_literal: true

module HuggingFaceStorage
  # Manages authentication tokens for API requests.
  class Authentication
    # Abstract base class for token providers.
    class TokenProvider
      # Returns the bearer token.
      #
      # @return [String] the token
      def token
        raise NotImplementedError
      end

      # Returns the Authorization header hash.
      #
      # @return [Hash{String => String}] the Authorization header
      def auth_header
        { "Authorization" => "Bearer #{token}" }
      end
    end

    # Provides a static token from an argument or the HF_TOKEN environment variable.
    class StaticTokenProvider < TokenProvider
      # Creates a static token provider.
      #
      # @param token [String, nil] the bearer token, falls back to HF_TOKEN env var
      # @raise [AuthenticationError] if no token is available
      def initialize(token: nil)
        super()
        @token = token || ENV.fetch("HF_TOKEN", nil)
        return unless @token.nil? || @token.empty?

        raise AuthenticationError,
              "Token is required. Provide via argument or HF_TOKEN env var."
      end

      # @return [String] the bearer token
      attr_reader :token
    end

    # @return [String] the bearer token
    attr_reader :token

    # Creates an authentication instance.
    #
    # @param token [String, nil] a static bearer token
    # @param token_provider [TokenProvider, nil] custom token provider
    def initialize(token: nil, token_provider: nil)
      @token_provider = token_provider || StaticTokenProvider.new(token: token)
      @token = @token_provider.token
    end

    # Returns the Authorization header hash.
    #
    # @return [Hash{String => String}] the Authorization header
    def auth_header
      @token_provider.auth_header
    end
  end
end
