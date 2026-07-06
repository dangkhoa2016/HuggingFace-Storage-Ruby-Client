# frozen_string_literal: true

require_relative "validation"
require_relative "config_defaults"

module HuggingFaceStorage
  # HTTP connection and transport configuration.
  class HttpConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :base_url, :idle_timeout, :open_timeout, :read_timeout, :write_timeout, :stream_chunk_size, :debug_mode

    def initialize(
      base_url: "https://huggingface.co",
      idle_timeout: 60,
      open_timeout: 30,
      read_timeout: 300,
      write_timeout: 30,
      stream_chunk_size: 65_536,
      debug_mode: false
    )
      @base_url = base_url
      @idle_timeout = validate_positive(idle_timeout, "idle_timeout")
      @open_timeout = validate_positive(open_timeout, "open_timeout")
      @read_timeout = validate_positive(read_timeout, "read_timeout")
      @write_timeout = validate_positive(write_timeout, "write_timeout")
      @stream_chunk_size = validate_positive(stream_chunk_size, "stream_chunk_size")
      @debug_mode = debug_mode
      freeze
    end
    def self.default
      new
    end
  end

  # Retry with exponential backoff configuration.
  class RetryConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :max_retries, :retry_delay, :max_retry_delay

    def initialize(max_retries: 3, retry_delay: 1, max_retry_delay: 60)
      @max_retries = validate_non_negative(max_retries, "max_retries")
      @retry_delay = validate_positive(retry_delay, "retry_delay")
      @max_retry_delay = validate_positive(max_retry_delay, "max_retry_delay")
      freeze
    end
    def self.default
      new
    end
  end

  # Batch operation limits and thresholds.
  class BatchConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :batch_size, :delete_batch_size, :copy_batch_size, :batch_threshold, :batch_memory_limit,
                :small_size_threshold

    def initialize(
      batch_size: 1000, delete_batch_size: 20, copy_batch_size: 20,
      batch_threshold: 100 * 1024 * 1024, batch_memory_limit: 200 * 1024 * 1024, small_size_threshold: 100 * 1024
    )
      @batch_size = validate_positive(batch_size, "batch_size")
      @delete_batch_size = validate_positive(delete_batch_size, "delete_batch_size")
      @copy_batch_size = validate_positive(copy_batch_size, "copy_batch_size")
      @batch_threshold = validate_positive(batch_threshold, "batch_threshold")
      @batch_memory_limit = validate_positive(batch_memory_limit, "batch_memory_limit")
      @small_size_threshold = validate_positive(small_size_threshold, "small_size_threshold")
      freeze
    end
    def self.default
      new
    end
  end

  # Logging output limits.
  class LogConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :body_log_max, :colorize_cache_max

    def initialize(body_log_max: 2000, colorize_cache_max: 200)
      @body_log_max = validate_positive(body_log_max, "body_log_max")
      @colorize_cache_max = validate_positive(colorize_cache_max, "colorize_cache_max")
      freeze
    end
    def self.default
      new
    end
  end

  # Cache TTL and size settings.
  class CacheConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :metadata_cache_ttl, :xet_token_cache_size, :token_expiry_buffer

    def initialize(metadata_cache_ttl: 60, xet_token_cache_size: 1000, token_expiry_buffer: 60)
      @metadata_cache_ttl = validate_positive(metadata_cache_ttl, "metadata_cache_ttl")
      @xet_token_cache_size = validate_positive(xet_token_cache_size, "xet_token_cache_size")
      @token_expiry_buffer = validate_positive(token_expiry_buffer, "token_expiry_buffer")
      freeze
    end
    def self.default
      new
    end
  end

  # Parallelism settings for downloads and verification.
  class ParallelConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :parallel_downloads, :parallel_verify, :stream_threshold

    def initialize(parallel_downloads: 4, parallel_verify: 8, stream_threshold: 10 * 1024 * 1024)
      @parallel_downloads = validate_positive(parallel_downloads, "parallel_downloads")
      @parallel_verify = validate_positive(parallel_verify, "parallel_verify")
      @stream_threshold = validate_positive(stream_threshold, "stream_threshold")
      freeze
    end
    def self.default
      new
    end
  end

  # Edit operation constraints.
  class EditConfig
    include ConfigValidation
    include ConfigDefaults

    attr_reader :max_edit_file_size

    def initialize(max_edit_file_size: 50 * 1024 * 1024)
      @max_edit_file_size = max_edit_file_size ? validate_positive(max_edit_file_size, "max_edit_file_size") : nil
      freeze
    end
    def self.default
      new
    end
  end
end
