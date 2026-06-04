# frozen_string_literal: true

module HuggingFaceStorage
  # Logs HTTP request/response details with sensitive-header masking.
  # @api private
  # :nodoc:
  class RequestLogger
    # HTTP headers whose values should be masked in logs.
    SENSITIVE_HEADERS = %w[authorization cookie set-cookie x-xet-access-token].freeze
    # Hash lookup for O(1) sensitive header detection.
    SENSITIVE_LOOKUP = SENSITIVE_HEADERS.to_h { |h| [h, true] }.freeze
    # Content types whose response bodies are logged as text.
    TEXT_CONTENT_TYPES = %w[application/json text/ application/xml application/x-ndjson].freeze

    # Request headers worth logging.
    USEFUL_REQUEST_HEADERS  = %w[content-type content-length].freeze
    # Response headers worth logging.
    USEFUL_RESPONSE_HEADERS = %w[content-type content-length x-request-id ratelimit].freeze

    # Initializes a new RequestLogger.
    #
    # @param logger [Logger] the logger instance
    # @param config [Configuration] the configuration object (for body_log_max)
    def initialize(logger:, config:)
      @logger = logger
      @config = config
    end

    # Logs an HTTP request with selected headers and body.
    #
    # @param uri [URI] the request URI
    # @param request [Net::HTTPRequest] the request object
    # @return [void]
    def log_request(uri, request)
      @logger.debug { "#{request.method} #{uri}" }
      USEFUL_REQUEST_HEADERS.each do |key|
        val = request[key]
        @logger.debug { "  #{key}: #{mask_sensitive(key, val)}" } if val
      end
      return unless request.body && !request.body.empty?

      @logger.debug { "  Request Body: #{format_body(request.body)}" }
    end

    # Logs an HTTP response with selected headers and body.
    #
    # @param _uri [URI] the request URI (unused)
    # @param response [Net::HTTPResponse] the response object
    # @return [void]
    def log_response(_uri, response)
      @logger.debug { "  Response: HTTP #{response.code}" }
      USEFUL_RESPONSE_HEADERS.each do |key|
        val = response[key]
        @logger.debug { "  #{key}: #{mask_sensitive(key, val)}" } if val
      end
      body = response.body
      return unless body && !body.empty?

      content_type = response["content-type"].to_s.downcase
      if TEXT_CONTENT_TYPES.any? { |ct| content_type.include?(ct) }
        @logger.debug { "  Response Body: #{format_body(body)}" }
      else
        @logger.debug { "  Response Body: (binary, #{body.bytesize} bytes)" }
      end
    end

    private

    # Masks sensitive header values as "[REDACTED]".
    #
    # @param key [String] header name
    # @param value [String] header value
    # @return [String] the original value or "[REDACTED]"
    def mask_sensitive(key, value)
      return value unless SENSITIVE_LOOKUP[key.downcase]

      "[REDACTED]"
    end

    # Truncates a body string at the configured log limit.
    #
    # @param body [String, nil] the body to format
    # @return [String] the formatted (possibly truncated) body
    def format_body(body)
      return "(empty)" if body.nil? || body.empty?

      max = @config.body_log_max
      return body if body.bytesize <= max

      "#{body.byteslice(0, max)}... (#{body.bytesize} bytes total, truncated)"
    end
  end
end
