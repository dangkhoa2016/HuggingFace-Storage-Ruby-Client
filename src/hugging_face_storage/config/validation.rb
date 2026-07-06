# frozen_string_literal: true

module HuggingFaceStorage
  # Shared validation helpers for configuration Data.define classes.
  # @api private
  # :nodoc:
  module ConfigValidation
    private

    def validate_positive(value, name)
      return value if value.is_a?(Numeric) && value.positive?

      raise ArgumentError, "#{name} must be a positive integer, got #{value.inspect}"
    end

    def validate_non_negative(value, name)
      return value if value.is_a?(Numeric) && value >= 0

      raise ArgumentError, "#{name} must be non-negative, got #{value.inspect}"
    end
  end
end
