# frozen_string_literal: true

require "logger"
require "time"
require "stringio"
require "pathname"
require "delegate"
require "json"

module HuggingFaceStorage
  # Wraps an IO to prevent close/closed? from propagating to the underlying stream.
  # Used to protect shared streams ($stdout, $stderr) from being closed by ::Logger::LogDevice.
  class NoopCloseIO < SimpleDelegator
    # Prevents the IO from being closed.
    #
    # @return [void]
    def close; end

    # Always returns false, preventing close propagation.
    #
    # @return [false]
    def closed?
      false
    end
  end

  private_constant :NoopCloseIO

  # Log format definitions for HFLogger.
  # @api private
  module HFLoggerFormats
    FORMATS = {
      default: lambda { |time, level, message, color|
        ts = color ? Color::GREEN + time.strftime("%H:%M:%S.%3N") + Color::RESET : time.strftime("%H:%M:%S.%3N")
        lvl_color = color ? (Colorize::LEVEL_COLORS[level] || "") : ""
        lvl = lvl_color + level.ljust(5) + (color ? Color::RESET : "")
        msg = color ? Colorize.colorize_message(level, message) : message
        "[#{ts}] #{lvl} #{msg}"
      },
      plain: lambda { |time, level, message, color|
        ts = if color
               Color::GREEN + time.strftime("%Y-%m-%d %H:%M:%S.%3N") + Color::RESET
             else
               time.strftime("%Y-%m-%d %H:%M:%S.%3N")
             end
        lvl = color ? (Colorize::LEVEL_COLORS[level] || "") + level + Color::RESET : level
        msg = color ? Colorize.colorize_message(level, message) : message
        "[#{ts}] [#{lvl}] #{msg}"
      },
      json: lambda { |time, level, message, _color|
        JSON.generate({ timestamp: time.iso8601(3), level: level, message: message })
      },
      short: lambda { |time, level, message, color|
        ts = color ? Color::GREEN + time.strftime("%H:%M:%S.%3N") + Color::RESET : time.strftime("%H:%M:%S.%3N")
        msg = color ? Colorize.colorize_message(level, message) : message
        "#{level[0]} #{ts} #{msg}"
      },
    }.freeze
  end

  # Structured logger with colorized output, multiple formats, and file output support.
  class HFLogger
    include HFLoggerFormats

    # Log severity levels mapped from symbols to ::Logger constants.
    LEVELS = { debug: ::Logger::DEBUG, info: ::Logger::INFO, warn: ::Logger::WARN,
               error: ::Logger::ERROR, fatal: ::Logger::FATAL }.freeze

    # Initializes a new HFLogger.
    #
    # @param level [Symbol, String, Integer] log level (:debug, :info, :warn, :error, :fatal)
    # @param output [IO, String, Pathname, Symbol] output destination
    # @param format [Symbol, Proc] log format (:default, :plain, :json, :short)
    # @param color [Symbol, Boolean] color mode (:auto, true, false)
    def initialize(level: :info, output: $stdout, format: :default, color: :auto)
      @io = resolve_output(output)
      @color = resolve_color(color, @io)

      @logger = ::Logger.new(@io)
      @logger.level = resolve_level(level)
      @format = resolve_format(format)

      @logger.formatter = proc do |severity, datetime, _progname, msg|
        "#{@format.call(datetime, severity, msg, @color)}\n"
      end
    end

    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def debug(message = nil, &block)
      log(:debug, message, &block)
    end

    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def info(message = nil, &block)
      log(:info, message, &block)
    end

    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def warn(message = nil, &block)
      log(:warn, message, &block)
    end

    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def error(message = nil, &block)
      log(:error, message, &block)
    end

    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def fatal(message = nil, &block)
      log(:fatal, message, &block)
    end

    # @return [Symbol] the current log level (:debug, :info, :warn, :error, :fatal)
    def level
      LEVELS.key(@logger.level)
    end

    # Sets the log level.
    #
    # @param new_level [Symbol, String, Integer] new log level
    # @return [void]
    def level=(new_level)
      @logger.level = resolve_level(new_level)
    end

    # Closes the underlying logger.
    # Safe to call multiple times — subsequent calls are no-ops.
    # The underlying IO is managed by ::Logger and its LogDevice.
    #
    # @return [void]
    def close
      return if @closed

      @closed = true
      @logger.close
    end

    # @return [Symbol] the current log format (:default or :json)
    def format
      FORMATS.key(@format) || @format
    end

    # Sets the log format.
    #
    # @param new_format [Symbol, Proc] new log format
    # @return [void]
    def format=(new_format)
      @format = resolve_format(new_format)
      @logger.formatter = proc do |severity, datetime, _progname, msg|
        "#{@format.call(datetime, severity, msg, @color)}\n"
      end
    end

    # Delegates to Colorize for backward compatibility.
    def self.colorize_message(level, message)
      Colorize.colorize_message(level, message)
    end

    private

    # Routes a log message at the given severity.
    #
    # @param level_sym [Symbol] severity level
    # @param message [String, nil] log message
    # @yield optional block producing a message
    # @return [void]
    def log(level_sym, message, &block)
      severity = LEVELS[level_sym] || ::Logger::INFO
      if block
        @logger.add(severity, &block)
      else
        @logger.add(severity, message)
      end
    end

    # Resolves a level value to a ::Logger severity integer.
    #
    # @param level [Symbol, String, Integer] log level
    # @return [Integer] ::Logger severity constant
    def resolve_level(level)
      case level
      when Symbol, String then LEVELS[level.to_sym] || ::Logger::INFO
      when Integer        then level
      else                     ::Logger::INFO
      end
    end

    # Determines whether color output should be enabled.
    #
    # @param color [Symbol, Boolean] color setting (:auto, true, false)
    # @param io [IO] output IO
    # @return [Boolean] whether color is enabled
    def resolve_color(color, io)
      case color
      when :auto  then io.respond_to?(:isatty) && io.isatty
      when true   then true
      else             false
      end
    end

    # Resolves an output destination to an IO object.
    #
    # @param output [IO, String, Pathname, Symbol] output destination
    # @return [IO] resolved IO object
    def resolve_output(output)
      case output
      when String, Pathname
        path = output.to_s
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        file = File.open(path, "a")
        file.sync = true
        @file_io = file
        TeeIO.new($stdout, StripIO.new(file))
      when :stdout, $stdout then NoopCloseIO.new($stdout)
      when :stderr, $stderr then NoopCloseIO.new($stderr)
      when IO, StringIO, ->(o) { o.respond_to?(:write) } then output
      # The else and when :stdout intentionally share the same fallback behavior.
      else NoopCloseIO.new($stdout)
      end
    end

    # Resolves a format value to a format lambda.
    #
    # @param format [Symbol, Proc] format specification
    # @return [Proc] format lambda
    def resolve_format(format)
      case format
      when Symbol then FORMATS[format] || FORMATS[:default]
      when Proc   then format
      else             FORMATS[:default]
      end
    end
  end
end
