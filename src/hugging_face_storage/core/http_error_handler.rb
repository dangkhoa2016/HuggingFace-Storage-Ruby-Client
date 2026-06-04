# frozen_string_literal: true

require "json"

module HuggingFaceStorage
  # Maps HTTP response status codes to typed error exceptions.
  # @api private
  # :nodoc:
  module HttpErrorHandler
    # Raises a typed error exception based on the HTTP response status code.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @return [nil] if the status is successful (2xx)
    # @raise [AuthenticationError] on 401/403
    # @raise [NotFoundError] on 404
    # @raise [ConflictError] on 409
    # @raise [ValidationError] on 422
    # @raise [RateLimitError] on 429
    # @raise [ApiError] on other non-2xx statuses
    def self.raise_for_status!(response)
      code = response.code.to_i
      body = response.body

      case code
      when 200..299
        nil
      when ApiPaths::Status::UNAUTHORIZED, ApiPaths::Status::FORBIDDEN
        raise AuthenticationError, "Authentication failed (HTTP #{code}): #{extract_error_message(response)}"
      when ApiPaths::Status::NOT_FOUND
        raise NotFoundError, "Resource not found (HTTP #{code}): #{extract_error_message(response)}"
      when ApiPaths::Status::CONFLICT
        raise ConflictError, "Conflict (HTTP #{code}): #{extract_error_message(response)}"
      when ApiPaths::Status::UNPROCESSABLE
        errors = parse_validation_errors(body)
        raise ValidationError.new("Validation failed", errors: errors, status: code, body: body)
      when ApiPaths::Status::TOO_MANY_REQUESTS
        retry_after = response["Retry-After"]&.to_i
        raise RateLimitError.new("Rate limit exceeded", retry_after: retry_after, status: code, body: body)
      else
        raise ApiError.new(
          message: "API request failed (HTTP #{code}): #{extract_error_message(response)}",
          status: code, body: body
        )
      end
    end

    # Extracts a human-readable error message from the response body.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @return [String] the extracted or fallback error message
    def self.extract_error_message(response)
      body = response.body
      return "HTTP #{response.code}" if body.nil? || body.empty?

      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      message = if parsed.is_a?(Hash)
                  parsed["error"] || parsed["message"]
                elsif parsed.is_a?(String)
                  parsed
                end
      return message.to_s unless message.to_s.empty?

      body.to_s[0, 200]
    end

    # Parses validation error details from a JSON error response body.
    #
    # @param body [String, nil] the raw response body
    # @return [Hash] parsed error details or empty hash
    def self.parse_validation_errors(body)
      return {} unless body

      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      return {} unless parsed

      parsed.is_a?(Hash) ? parsed.fetch("errors", parsed) : {}
    end
  end
end
