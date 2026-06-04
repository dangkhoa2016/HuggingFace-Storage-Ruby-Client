# frozen_string_literal: true

module HuggingFaceStorage
  # Shared serialization for configuration value objects.
  module ConfigDefaults
    def to_h
      instance_variables.to_h do |iv|
        [iv.to_s.delete("@").to_sym, instance_variable_get(iv)]
      end
    end
  end
end
