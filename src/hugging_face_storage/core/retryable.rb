# frozen_string_literal: true

require "net/http"
require "time"

module HuggingFaceStorage
  # Retry logic with exponential backoff and cancellation support.
  class Retryable
    # @return [Array<Class>] exception classes that trigger automatic retries
    RETRYABLE_EXCEPTIONS = [
      Errno::ECONNRESET, Errno::ECONNREFUSED,
      Net::OpenTimeout, Net::ReadTimeout
    ].freeze
    # @return [Integer] maximum retry-after seconds to respect from server
    RETRY_AFTER_MAX = 300

    # Initializes a new Retryable.
    #
    # @param logger [Logger, nil] the logger instance
    def initialize(logger: nil)
      @logger = logger
    end

    # Sleeps for +seconds+ but can be interrupted early via +cancel_token+.
    #
    # Unsubscribes the cancel callback after waking to avoid leaking
    # closures in the CancelToken's callback list across retry cycles.
    #
    # @param seconds [Numeric] sleep duration
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @return [void]
    def interruptible_sleep(seconds, cancel_token)
      return sleep(seconds) unless cancel_token

      mutex = Mutex.new
      cond = ConditionVariable.new
      cancelled = false

      cancel_cb = lambda {
        mutex.synchronize do
          cancelled = true
          cond.signal
        end
      }

      cancel_token.on_cancel(&cancel_cb)

      mutex.synchronize do
        cond.wait(mutex, Float(seconds)) unless cancelled
      end
    ensure
      cancel_token&.cancel_subscription(cancel_cb) if cancel_cb
    end

    # Calls the block and retries on retryable errors using exponential backoff.
    #
    # @param config [Configuration] retry configuration
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param logger [Logger, nil] optional logger for warnings
    # @yield [Integer] passes current retry count
    # @yieldreturn [Net::HTTPResponse] the HTTP response
    # @return [Net::HTTPResponse] the final response after successful or non-retryable response
    def retry_with_backoff(config, cancel_token: nil, logger: nil, &block)
      execute_with_retry_loop(config, cancel_token, logger, &block)
    end

    # Computes the sleep delay with exponential backoff and jitter.
    #
    # @param retry_count [Integer] current retry attempt number
    # @param config [Configuration] retry configuration
    # @return [Float] sleep delay in seconds
    def compute_sleep_delay(retry_count, config)
      [config.retry_delay.to_f * (2**retry_count) * (0.5 + rand), config.max_retry_delay.to_f].min
    end

    # Core retry loop — yields to the block and retries on retryable errors.
    #
    # @param config [Configuration] retry configuration
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param logger [Logger, nil] optional logger
    # @yield [Integer] passes current retry count
    # @yieldreturn [Net::HTTPResponse] the HTTP response
    # @return [Net::HTTPResponse] the final response
    def execute_with_retry_loop(config, cancel_token, logger, &block)
      retries = 0
      loop do
        cancel_token&.raise_if_cancelled!
        begin
          response = yield(retries)
          if response.is_a?(Net::HTTPResponse) && retryable_http_status?(response.code.to_i) &&
             retries < config.max_retries
            delay = compute_retry_delay(response, config, retries)
            retries += 1
            logger&.warn("Retry #{retries}/#{config.max_retries} after #{delay.round(1)}s (HTTP #{response.code})")
            interruptible_sleep(delay, cancel_token)
            next
          end
          return response
        rescue *RETRYABLE_EXCEPTIONS, ApiError => e
          retries = handle_retry_error(e, retries, config, cancel_token, logger)
        end
      end
    end

    private

    def retryable_http_status?(code)

      ApiPaths::RETRYABLE_HTTP_STATUSES.include?(code)

    end

    def retryable_api_error?(error)

      error.is_a?(ApiError) && error.status ? retryable_http_status?(error.status) : false

    end

    # Handles a retryable error — raises if max retries exceeded, otherwise sleeps and returns updated count.
    #
    # @param error [Exception] the raised error
    # @param retries [Integer] current retry count
    # @param config [Configuration] retry configuration
    # @param cancel_token [CancelToken, nil] optional cancellation token
    # @param logger [Logger, nil] optional logger
    # @return [Integer] updated retry count
    def handle_retry_error(error, retries, config, cancel_token, logger)
      case error
      when *RETRYABLE_EXCEPTIONS
        raise if retries >= config.max_retries
      when ApiError
        raise unless retryable_api_error?(error) && retries < config.max_retries
      else
        raise error
      end
      delay = compute_sleep_delay(retries, config)
      new_retries = retries + 1
      status = "(HTTP #{error.status})" if error.is_a?(ApiError)
      logger&.warn("Retry #{new_retries}/#{config.max_retries} after #{delay.round(1)}s: #{error.class}#{status}")
      interruptible_sleep(delay, cancel_token)
      new_retries
    end

    # Computes the retry delay considering the server's retry-after header and exponential backoff.
    #
    # @param response [Net::HTTPResponse] the HTTP response
    # @param config [Configuration] retry configuration
    # @param retries [Integer] current retry attempt number
    # @return [Float] delay in seconds
    def compute_retry_delay(response, config, retries)
      backoff = [config.retry_delay.to_f * (2**retries) * (0.5 + rand), config.max_retry_delay.to_f].min
      server_hint = parse_retry_after(response["retry-after"])
      return backoff unless server_hint

      [server_hint, config.max_retry_delay, RETRY_AFTER_MAX].min
    end

    # Parses the Retry-After header value into seconds.
    #
    # @param value [String, nil] the Retry-After header value
    # @return [Float, nil] delay in seconds, or nil if unparseable
    def parse_retry_after(value)
      return nil if value.nil? || value.empty?

      if /\A\s*\d+(\.\d+)?\s*\z/.match?(value)
        seconds = value.to_f
        return seconds >= 0 ? seconds : nil
      end

      time = begin
        Time.httpdate(value)
      rescue StandardError
        nil
      end
      return nil unless time

      delta = time.to_f - Time.now.to_f
      delta.positive? ? delta : 0
    end
  end
end
