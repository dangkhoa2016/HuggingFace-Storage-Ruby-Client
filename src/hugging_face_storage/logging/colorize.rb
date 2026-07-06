# frozen_string_literal: true

module HuggingFaceStorage
  # Applies highlighting patterns to log messages for colorized terminal output.
  # Maintains a thread-safe cache of pre-computed highlight positions.
  class Colorize
    # Maps log severity strings to ANSI color constants.
    LEVEL_COLORS = {
      "DEBUG" => Color::DIM + Color::WHITE,
      "INFO" => Color::BRIGHT_CYAN,
      "WARN" => Color::BRIGHT_YELLOW,
      "ERROR" => Color::BRIGHT_RED,
      "FATAL" => Color::BOLD + Color::BRIGHT_RED,
    }.freeze

    # Patterns and their associated colors for highlighting parts of log messages.
    HIGHLIGHT_PATTERNS = [
      [/\b(HTTP\s+[45]\d{2})\b/, Color::BRIGHT_RED],
      [/\b(HTTP\s+[0-35-9]\d{2})\b/, Color::BRIGHT_GREEN],
      [/\b(\d+(?:\.\d+)?\s*(?:B|KB|MB|GB|TB))\b/, Color::BRIGHT_YELLOW],
      [/\b(\d+(?:\.\d+)?\s*ms)\b/, Color::BRIGHT_MAGENTA],
      [/\b(\d+\s+file\(s\))/, Color::BRIGHT_WHITE],
      [%r{(\[\d+/\d+\])}, Color::BOLD + Color::BRIGHT_CYAN],
      [%r{(/?[\w.-]+(?:/[\w.-]+)+)}, Color::CYAN],
      [/\b((?:model|dataset|space|bucket):[^\s]+)/, Color::BRIGHT_BLUE],
      [/\b(Done:)/, Color::BRIGHT_GREEN],
      [/([\w-]+(?:\s+[\w-]+)*\s+complete:?(?!\w)|copied|uploaded|downloaded)\b/i, Color::BRIGHT_GREEN],
    ].freeze

    # A single regex that matches any of the highlight patterns (used as a fast pre-check).
    HIGHLIGHT_CHECK_RE = Regexp.union(HIGHLIGHT_PATTERNS.map(&:first)).freeze

    # Maximum number of cached highlight results.
    COLORIZE_CACHE_MAX = Configuration.default.colorize_cache_max

    @mutex = Mutex.new
    @cache = {}

    # Applies highlighting patterns to a log message for colorized output.
    #
    # @param level [String] log severity level
    # @param message [String] the log message
    # @return [String] colorized message string
    def self.colorize_message(level, message)
      return Color::DIM + message + Color::RESET if level == "DEBUG"
      return message unless message.match?(HIGHLIGHT_CHECK_RE)

      cache_key = message

      @mutex.synchronize do
        if (cached = @cache[cache_key])
          result = message.dup
          cached.reverse_each do |m|
            result[m[:start]...m[:end_pos]] = m[:color] + m[:text] + Color::RESET
          end
          return result
        end

        matches = build_matches(message)

        @cache.shift if @cache.size >= COLORIZE_CACHE_MAX
        @cache[cache_key] = matches

        apply_highlights(message, matches)
      end
    end

    # Clears the highlight cache.
    #
    # @return [void]
    def self.clear_cache
      @mutex.synchronize { @cache.clear }
    end

    # @return [Integer] current cache size
    def self.cache_size
      @mutex.synchronize { @cache.size }
    end

    # Builds a sorted, non-overlapping list of highlight matches for a message.
    #
    # @param message [String] the log message
    # @return [Array<Hash{Symbol => Integer, String}>] match entries with :start, :end_pos, :color, :text
    private_class_method def self.build_matches(message)
      # @type var matches: Array[Hash[Symbol, (Integer | String)]]
      matches = []
      HIGHLIGHT_PATTERNS.each do |pattern, color|
        message.scan(pattern) do
          m = Regexp.last_match # : MatchData
          matches << { start: m.begin(0), end_pos: m.end(0), color: color, text: m[0] }
        end
      end

      matches.sort_by! { |m| [m[:start], -m[:end_pos]] }

      # @type var filtered: Array[Hash[Symbol, (Integer | String)]]
      matches.each_with_object([]) do |m, filtered|
        filtered << m if filtered.empty? || m[:start] >= filtered.last[:end_pos]
      end
    end

    # Applies highlight replacements to a message string.
    #
    # @param message [String] the original log message
    # @param matches [Array<Hash{Symbol => Integer, String}>] sorted, non-overlapping match entries
    # @return [String] colorized message
    private_class_method def self.apply_highlights(message, matches)
      result = message.dup
      matches.reverse_each do |m|
        result[m[:start]...m[:end_pos]] = m[:color] + m[:text] + Color::RESET
      end
      result
    end
  end
end
