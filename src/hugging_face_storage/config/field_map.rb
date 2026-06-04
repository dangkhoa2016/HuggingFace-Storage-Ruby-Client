# frozen_string_literal: true

module HuggingFaceStorage
  # Maps top-level configuration option names to their sub-config keys.
  # @return [Hash{Symbol => Symbol}]
  FIELD_MAP = {
    base_url: :http, idle_timeout: :http, open_timeout: :http,
    read_timeout: :http, write_timeout: :http, stream_chunk_size: :http, debug_mode: :http,
    max_retries: :retry_config, retry_delay: :retry_config, max_retry_delay: :retry_config,
    batch_size: :batch, delete_batch_size: :batch, copy_batch_size: :batch,
    batch_threshold: :batch, batch_memory_limit: :batch, small_size_threshold: :batch,
    body_log_max: :log, colorize_cache_max: :log,
    metadata_cache_ttl: :cache, xet_token_cache_size: :cache, token_expiry_buffer: :cache,
    parallel_downloads: :parallel, parallel_verify: :parallel, stream_threshold: :parallel,
    max_edit_file_size: :edit
  }.freeze
end
