# frozen_string_literal: true

require "delegate"

module HuggingFaceStorage
  # IO wrapper that strips ANSI escape codes from written data.
  class StripIO < SimpleDelegator
    # Regex matching ANSI escape codes to strip.
    STRIP_RE = /\e\[[0-9;]*m/
    # Writes data with ANSI escape codes removed.
    # @param data [String] input data
    # @return [Integer] bytes written
    def write(data)
      super(data.gsub(STRIP_RE, ""))
    end
  end

  # IO wrapper that duplicates writes to multiple IO objects.
  class TeeIO < SimpleDelegator
    # Streams that should not be closed by TeeIO#close.
    SPECIAL_STREAMS = [$stdout, $stderr].freeze

    def initialize(*ios)
      @ios = ios
      super(ios.first)
    end

    # Writes +data+ to all wrapped IO objects.
    # @param data [String] input data
    # @return [Integer] bytes written
    def write(data)
      @ios.each { |io| io.write(data) }
    end
    # @return [void]
    def close
      @ios.each { |io| io.close unless SPECIAL_STREAMS.include?(io) }
    end
  end
end
