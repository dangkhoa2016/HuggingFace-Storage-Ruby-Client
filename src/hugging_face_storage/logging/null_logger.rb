# frozen_string_literal: true

module HuggingFaceStorage
  # No-op logger that implements the HFLogger interface without output.
  class NullLogger
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def debug(message = nil, &block) end
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def info(message = nil, &block) end
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def warn(message = nil, &block) end
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def error(message = nil, &block) end
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def fatal(message = nil, &block) end

    # @return [Symbol] always :info
    # @return [Symbol] always :info
    def level
      :info
    end

    # Sets the log level (no-op).
    # @param _ [Symbol] ignored
    # @return [void]
    def level=(_); end

    # @return [Symbol] always :default
    def format
      :default
    end

    # Sets the log format (no-op).
    # @param _ [Symbol] ignored
    # @return [void]
    def format=(_); end
    # @return [void]
    def close; end
  end
end
