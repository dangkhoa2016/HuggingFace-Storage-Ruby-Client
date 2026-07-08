# frozen_string_literal: true

require_relative "sub_configs"
require_relative "field_map"

module HuggingFaceStorage
  # Central configuration object composed of typed sub-configurations.
  class Configuration
    HttpConfig = ::HuggingFaceStorage::HttpConfig
    RetryConfig = ::HuggingFaceStorage::RetryConfig
    BatchConfig = ::HuggingFaceStorage::BatchConfig
    LogConfig = ::HuggingFaceStorage::LogConfig
    CacheConfig = ::HuggingFaceStorage::CacheConfig
    ParallelConfig = ::HuggingFaceStorage::ParallelConfig
    EditConfig = ::HuggingFaceStorage::EditConfig
    FIELD_MAP = ::HuggingFaceStorage::FIELD_MAP

    attr_reader :http, :retry_config, :batch, :log, :cache, :parallel, :edit

    def initialize(http: HttpConfig.default,
                   retry_config: RetryConfig.default,
                   batch: BatchConfig.default,
                   log: LogConfig.default,
                   cache: CacheConfig.default,
                   parallel: ParallelConfig.default,
                   edit: EditConfig.default,
                   **overrides)
      @http = http
      @retry_config = retry_config
      @batch = batch
      @log = log
      @cache = cache
      @parallel = parallel
      @edit = edit
      apply_overrides(overrides) unless overrides.empty?

      freeze
    end

    def apply_overrides(overrides)
      subs = { http: @http, retry_config: @retry_config, batch: @batch,
               log: @log, cache: @cache, parallel: @parallel, edit: @edit }
      overrides.each do |key, value|
        sub_key = FIELD_MAP.fetch(key) { raise ArgumentError, "unknown configuration key: #{key.inspect}" }
        current = subs[sub_key]
        subs[sub_key] = current.class.new(**current.to_h, key => value) # steep:ignore
      end
      @http = subs[:http]
      @retry_config = subs[:retry_config]
      @batch = subs[:batch]
      @log = subs[:log]
      @cache = subs[:cache]
      @parallel = subs[:parallel]
      @edit = subs[:edit]
    end
    private :apply_overrides

    def base_url
      http.base_url
    end
    def idle_timeout
      http.idle_timeout
    end
    def open_timeout
      http.open_timeout
    end
    def read_timeout
      http.read_timeout
    end
    def write_timeout
      http.write_timeout
    end
    def stream_chunk_size
      http.stream_chunk_size
    end
    def debug_mode
      http.debug_mode
    end
    def max_retries
      retry_config.max_retries
    end
    def retry_delay
      retry_config.retry_delay
    end
    def max_retry_delay
      retry_config.max_retry_delay
    end
    def batch_size
      batch.batch_size
    end
    def delete_batch_size
      batch.delete_batch_size
    end
    def copy_batch_size
      batch.copy_batch_size
    end
    def batch_threshold
      batch.batch_threshold
    end
    def batch_memory_limit
      batch.batch_memory_limit
    end
    def small_size_threshold
      batch.small_size_threshold
    end
    def body_log_max
      log.body_log_max
    end
    def colorize_cache_max
      log.colorize_cache_max
    end
    def metadata_cache_ttl
      cache.metadata_cache_ttl
    end
    def xet_token_cache_size
      cache.xet_token_cache_size
    end
    def token_expiry_buffer
      cache.token_expiry_buffer
    end
    def parallel_downloads
      parallel.parallel_downloads
    end
    def parallel_verify
      parallel.parallel_verify
    end
    def stream_threshold
      parallel.stream_threshold
    end
    def max_edit_file_size
      edit.max_edit_file_size
    end

    def retry_settings
      @retry_config
    end
    define_method(:retry) { @retry_config }

    def self.default
      new
    end

    def with(**changes)
      self.class.new(**to_h, **changes)
    end
    def to_h
      { http: @http, retry_config: @retry_config, batch: @batch,
        log: @log, cache: @cache, parallel: @parallel, edit: @edit }
    end
  end
end
