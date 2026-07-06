# frozen_string_literal: true

module HuggingFaceStorage
  # Mixin for retrying CAS operations with automatic token refresh on auth failure.
  # @api private
  # :nodoc:
  module TokenRetryable
    private

    # Yields a token, retrying once with a refreshed token on 401/403 errors.
    #
    # @param bucket_id [String] the bucket ID
    # @param label [Symbol] token label (:read or :write)
    # @yield [String] the auth token
    # @return [Object] the return value of the block
    # @raise [ApiError] on non-auth errors
    def with_token_retry(bucket_id, label:)
      yield @token_manager.send(:"fetch_#{label}_token", bucket_id)[:token]
    rescue ApiError => e
      raise unless [401, 403].include?(e.status)

      @logger.warn do
        label_name = label.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
        "#{label_name} token invalidated (HTTP #{e.status}), refreshing and retrying"
      end
      @token_manager.send(:"invalidate_#{label}_token", bucket_id)
      yield @token_manager.send(:"fetch_#{label}_token", bucket_id)[:token]
    end
  end
end
