# frozen_string_literal: true

module HuggingFaceStorage
  # ANSI escape code constants for terminal color output.
  module Color
    # Reset all attributes.
    RESET  = "\e[0m"
    # Bold / bright mode.
    BOLD   = "\e[1m"
    # Dim / half-bright mode.
    DIM    = "\e[2m"

    # Black foreground.
    BLACK   = "\e[30m"
    # Red foreground.
    RED     = "\e[31m"
    # Green foreground.
    GREEN   = "\e[32m"
    # Yellow foreground.
    YELLOW  = "\e[33m"
    # Blue foreground.
    BLUE    = "\e[34m"
    # Magenta foreground.
    MAGENTA = "\e[35m"
    # Cyan foreground.
    CYAN    = "\e[36m"
    # White foreground.
    WHITE   = "\e[37m"

    # Bright red foreground.
    BRIGHT_RED     = "\e[91m"
    # Bright green foreground.
    BRIGHT_GREEN   = "\e[92m"
    # Bright yellow foreground.
    BRIGHT_YELLOW  = "\e[93m"
    # Bright blue foreground.
    BRIGHT_BLUE    = "\e[94m"
    # Bright magenta foreground.
    BRIGHT_MAGENTA = "\e[95m"
    # Bright cyan foreground.
    BRIGHT_CYAN    = "\e[96m"
    # Bright white foreground.
    BRIGHT_WHITE   = "\e[97m"

    # Strips ANSI escape codes from a string.
    #
    # @param str [String] input string possibly containing ANSI codes
    # @return [String] string with ANSI codes removed
    def self.strip(str)
      str.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
