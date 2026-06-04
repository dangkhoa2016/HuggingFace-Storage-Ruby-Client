# frozen_string_literal: true

module HuggingFaceStorage
  # Guards against copying unmigrated LFS files and raises an error if any are found.
  # @api private
  # :nodoc:
  class LfsGuard
    # Maximum number of offending files to include in the error message.
    MAX_REPORTED = 5

    # @param source_label [String] human-readable label for the source
    def initialize(source_label)
      @source_label = source_label
    end

    # Raises an Error if any +offenders+ are present.
    #
    # @param offenders [Array<Hash>] list of offending files with :path and :size keys
    # @raise [Error] if offenders is non-empty
    # @return [void]
    def check(offenders)
      return if offenders.empty?

      listed = offenders.first(MAX_REPORTED).map { |e| "'#{e[:path]}' (#{Utils.human_size(e[:size])})" }.join(", ")
      more = offenders.size > MAX_REPORTED ? " (and #{offenders.size - MAX_REPORTED} more)" : ""
      msg = "Cannot copy #{offenders.size} LFS file(s) from #{@source_label} that have not been " \
            "migrated to xet: #{listed}#{more}. Migrate these files to xet before copying."
      raise Error, msg
    end
  end
end
