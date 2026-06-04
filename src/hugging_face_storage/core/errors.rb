# frozen_string_literal: true

module HuggingFaceStorage
  # Base error class for all HuggingFaceStorage errors.
  class Error < StandardError; end
  # Raised on HTTP 401/403 — invalid or missing token.
  class AuthenticationError < Error; end
  # Raised on HTTP 404 — resource does not exist.
  class NotFoundError < Error; end
  # Raised on HTTP 409 — resource conflict.
  class ConflictError < Error; end

  # Generic API error with HTTP status code and response body.
  # @!attribute [r] status
  #   @return [Integer, nil] the HTTP status code
  # @!attribute [r] body
  #   @return [String, nil] the response body
  # @!attribute [r] hint
  #   @return [String, nil] a user-facing hint about the error
  class ApiError < Error
    attr_reader :status, :body, :hint

    # @param status [Integer, nil] HTTP status code
    # @param body [String, nil] response body
    # @param message [String] custom error message (default "API request failed")
    # @param hint [String, nil] user-facing hint
    def initialize(status: nil, body: nil, message: "API request failed", hint: nil)
      @status = status
      @body = body
      @hint = hint
      super(message)
    end
  end

  # Raised on HTTP 429 — rate limit exceeded.
  class RateLimitError < ApiError
    # @return [Integer, nil] the number of seconds to wait before retrying
    attr_reader :retry_after

    # @param message [String] error message (default "Rate limit exceeded")
    # @param retry_after [Integer, nil] retry-after seconds
    # @param status [Integer] HTTP status code (default 429)
    # @param body [String, nil] response body
    def initialize(message = "Rate limit exceeded", retry_after: nil, status: 429, body: nil)
      @retry_after = retry_after
      super(message: message, status: status, body: body)
    end
  end

  # Raised on HTTP 422 — validation error.
  class ValidationError < ApiError
    # @return [Hash] validation error details
    attr_reader :errors

    # @param message [String] error message (default "Validation failed")
    # @param errors [Hash] validation error details
    # @param status [Integer] HTTP status code (default 422)
    # @param body [String, nil] response body
    def initialize(message = "Validation failed", errors: {}, status: 422, body: nil)
      @errors = errors
      super(message: message, status: status, body: body)
    end
  end

  # Raised when a CancelToken is triggered during an operation.
  class CancelledError < Error; end
  # Raised when an operation exceeds its time limit.
  class TimeoutError < Error; end

  # Raised when a batch operation completes with partial failures.
  # Contains the BatchResult for inspection.
  # @!attribute [r] result
  #   @return [BatchResult] the partial results
  class PartialFailureError < Error
    attr_reader :result

    # @param message [String] error description
    # @param result [BatchResult] the partial batch result
    def initialize(message, result:)
      @result = result
      super(message)
    end
  end

  # Raised when paginated requests encounter failures.
  # @!attribute [r] pages_failed
  #   @return [Array<Integer>] page numbers that failed
  # @!attribute [r] errors
  #   @return [Array<Exception>] corresponding errors
  class PaginationError < Error
    attr_reader :pages_failed, :errors

    # @param pages_failed [Array<Integer>] page numbers that failed
    # @param errors [Array<Exception>] errors corresponding to each failed page
    def initialize(pages_failed, errors)
      @pages_failed = pages_failed
      @errors = errors
      page_list = pages_failed.first(5).join(", ")
      more = pages_failed.size > 5 ? " (and #{pages_failed.size - 5} more)" : ""
      super("Pagination failed on #{pages_failed.size} page(s): #{page_list}#{more}")
    end
  end
end
