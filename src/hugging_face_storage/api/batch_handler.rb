# frozen_string_literal: true

module HuggingFaceStorage
  # Handles batch API operations, splitting into chunks and parsing responses.
  # @api private
  # :nodoc:
  class BatchHandler
    # Initializes a new BatchHandler.
    #
    # @param logger [Logger] the logger instance
    # @param api_client [ApiClient] the API client (for build_uri and execute)
    def initialize(logger:, api_client:)
      @logger = logger
      @api = api_client
    end

    # Sends batch operations to the API, splitting into slices and parsing responses.
    #
    # @param bucket_id [String] the bucket identifier
    # @param operations [Array<Hash>] batch operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any operation fails (default true)
    # @return [BatchResult] the aggregated batch result
    def batch(bucket_id, operations, cancel_token: nil, raise_on_partial_failure: true)
      return BatchResult.new if operations.empty?

      @logger.info("Batch operation: #{operations.size} operation(s) on bucket #{bucket_id}")
      operations.each_with_index do |op, i|
        @logger.debug { "  [#{i + 1}/#{operations.size}] #{op[:type]} #{op[:path]}" }
      end

      process_batch_with_retry(bucket_id, operations, cancel_token, raise_on_partial_failure)
    end

    # Posts operations as NDJSON to the given path.
    #
    # @param path [String] API path
    # @param operations [Array<Hash>] batch operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @return [Array, nil] parsed JSON response or nil
    def post_ndjson(path, operations, cancel_token: nil)
      @logger.debug { "POST (NDJSON) #{path} operations=#{operations.size}" }
      uri = @api.build_uri(path)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = ApiPaths::CONTENT_TYPE_NDJSON
      request.body = operations.map { |op| JSON.generate(op) }.join("\n")
      @api.execute(uri, request, cancel_token: cancel_token)
    end

    private

    # Processes operations in slices, posting each slice with retry handling.
    #
    # @param bucket_id [String] the bucket identifier
    # @param operations [Array<Hash>] batch operations
    # @param cancel_token [CancelToken, nil] cooperative cancellation token
    # @param raise_on_partial_failure [Boolean] raise if any operation fails
    # @return [BatchResult] the aggregated batch result
    def process_batch_with_retry(bucket_id, operations, cancel_token, raise_on_partial_failure)
      result = BatchResult.new
      operations.each_slice(@api.config.batch_size) do |chunk|
        response = post_ndjson(ApiPaths.batch_path(bucket_id), chunk, cancel_token: cancel_token)
        parse_batch_response(result, response, chunk)
      rescue ApiError => e
        if e.status == 422
          parse_batch_failures(result, e.body, chunk)
        else
          chunk.each { |op| result.add_failure(op[:path] || "unknown", e.message) }
          raise
        end
      end

      result.raise_if_any! if raise_on_partial_failure && !result.success?
      result
    end

    # Parses a successful batch response into success/failure entries.
    #
    # @param result [BatchResult] the accumulating batch result
    # @param response [Array, nil] the parsed JSON response
    # @param operations [Array<Hash>] the original operations
    # @return [void]
    def parse_batch_response(result, response, operations)
      unless response.is_a?(Array)
        @logger.warn("Batch response is not an Array (got #{response.class}), treating all as success")
        operations.each { |op| result.add_success(op) }
        return
      end

      response.each_with_index do |entry, i|
        op = operations[i] || { path: "unknown" }
        if entry.is_a?(Hash) && (entry["error"] || entry["status"] == "error")
          error_msg = entry["error"] || entry["message"] || "unknown"
          result.add_failure(op[:path] || entry[ResponseFields::PATH] || "unknown", error_msg)
        else
          result.add_success(op)
        end
      end
    end

    # Parses a validation error body into success/failure entries.
    #
    # @param result [BatchResult] the accumulating batch result
    # @param body [String, nil] the raw error body
    # @param operations [Array<Hash>] the original operations
    # @return [void]
    def parse_batch_failures(result, body, operations)
      return unless body

      parsed = try_parse_json(body)
      unless parsed
        operations.each { |op| result.add_failure(op[:path], body[0..200]) }
        return
      end

      if parsed.is_a?(Array)
        parsed.each_with_index do |entry, i|
          classify_batch_entry(result, entry, operations[i])
        end
      else
        operations.each { |op| result.add_failure(op[:path], body[0..200]) }
      end
    end

    # Attempts to parse +body+ as JSON, returning +nil+ on parse errors.
    def try_parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    # Classifies a single batch response entry as success or failure.
    def classify_batch_entry(result, entry, operation)
      op = operation || { path: "unknown" }
      if entry.is_a?(Hash) && (entry["error"] || entry["status"] == "error")
        error_msg = entry["error"] || entry["message"] || "unknown"
        result.add_failure(op[:path] || entry[ResponseFields::PATH] || "unknown", error_msg)
      else
        result.add_success(op)
      end
    end
  end
end
