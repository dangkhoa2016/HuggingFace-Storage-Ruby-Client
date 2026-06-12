# frozen_string_literal: true

require "json"
require_relative "../logging/color"

module HuggingFaceStorage
  # Formatting helpers for CLI output (tables, JSON, client construction).
  module CLIFormatter
    module_function

    # Formats +rows+ as a text table with the given +headers+.
    #
    # @param rows [Array<Array>] table rows
    # @param headers [Array<String, Symbol>] column headers
    # @return [String] formatted table string
    def format_table(rows, headers)
      return "" if rows.empty?

      widths = compute_column_widths(rows, headers)
      header_line = headers.map.with_index { |h, i| h.to_s.ljust(widths[i]) }.join("  ")
      sep_line = widths.map { |w| "-" * w }.join("  ")
      body = rows.map { |r| r.map.with_index { |s, i| s.to_s.ljust(widths[i]) }.join("  ") }
      ([header_line, sep_line] + body).join("\n")
    end

    # Computes the maximum width for each column.
    def compute_column_widths(rows, headers)
      widths = headers.map { |h| h.to_s.length }
      rows.each do |row|
        row.each_with_index do |val, i|
          s = val.to_s
          widths[i] = [widths[i], s.length].max
        end
      end
      widths
    end

    # Formats data as pretty-printed JSON.
    #
    # @param data [Object] data to format
    # @return [String] JSON string
    def format_json(data)
      JSON.pretty_generate(data)
    end

    # Formats data as a table or JSON depending on +format+.
    #
    # @param data [Array] data to format
    # @param format [String] "json" or "table"
    # @param headers [Array<String, Symbol>, nil] column headers for table mode
    # @return [void]
    def format_output(data, format, headers: nil)
      case format
      when "json"
        puts format_json(data)
      else
        if headers
          puts format_table(data, headers)
        else
          data.each { |row| puts row }
        end
      end
    end

    # Formats an error message with optional hint, using ANSI colors.
    #
    # @param message [String] the error message
    # @param hint [String, nil] optional hint text (shown in yellow)
    # @return [String] formatted error string
    def format_error(message, hint: nil)
      formatted = Color::RED + "Error: #{message}" + Color::RESET
      formatted += "\n#{Color::YELLOW}Hint: #{hint}#{Color::RESET}" if hint
      formatted
    end

    # Parses a +namespace/name+ bucket spec into a hash.
    #
    # @param bucket_spec [#to_s] bucket specification
    # @return [Hash] keys :namespace and :name
    # @raise [ArgumentError] if spec is not in namespace/name form
    def parse_bucket(bucket_spec)
      parts = bucket_spec.to_s.split("/", 2)
      raise ArgumentError, "Bucket must be in form 'namespace/name', got: #{bucket_spec}" unless parts.length == 2

      { namespace: parts[0], name: parts[1] }
    end

    # Reads the HuggingFace session token from ~/.huggingface/token
    #
    # @return [String, nil] the token value or nil if file doesn't exist
    def read_session_token
      path = File.expand_path("~/.huggingface/token")
      File.read(path).strip
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      warn "Warning: Unable to read token from #{path}: #{e.message}"
      nil
    end

    # Builds a HuggingFaceStorage client from a bucket spec.
    #
    # @param bucket_spec [String] bucket in namespace/name form
    # @param token [String, nil] auth token (defaults to ENV["HF_TOKEN"], then ~/.huggingface/token)
    # @param log_level [String] log verbosity level (debug, info, warn, error)
    # @return [HuggingFaceStorage] configured client instance
    def build_client(bucket_spec, token: nil, log_level: "warn")
      spec = parse_bucket(bucket_spec)
      token ||= ENV.fetch("HF_TOKEN", nil)
      token ||= read_session_token
      HuggingFaceStorage.new(
        token: token,
        namespace: spec[:namespace],
        bucket: spec[:name],
        log_level: log_level.to_sym
      )
    end
  end
end
