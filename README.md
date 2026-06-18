# HuggingFace Storage — Ruby Client

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

<p align="center">
  <a href="https://github.com/dangkhoa2016/HuggingFace-Storage-Ruby-Client/actions"><img src="https://github.com/dangkhoa2016/HuggingFace-Storage-Ruby-Client/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/dangkhoa2016/HuggingFace-Storage-Ruby-Client/actions/workflows/benchmark.yml"><img src="https://github.com/dangkhoa2016/HuggingFace-Storage-Ruby-Client/actions/workflows/benchmark.yml/badge.svg" alt="Benchmarks"></a>
  <a href="https://rubygems.org/gems/hugging_face_storage"><img src="https://img.shields.io/gem/v/hugging_face_storage" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/hugging_face_storage"><img src="https://img.shields.io/gem/dt/hugging_face_storage" alt="Gem Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  <br>
  <img src="https://img.shields.io/badge/Ruby-2.7_3.0_3.1_3.2_3.3_3.4_4.0-red" alt="Ruby">
  <img src="https://img.shields.io/badge/coverage-100%25-brightgreen" alt="Coverage">
</p>

A pure Ruby library for managing files in [HuggingFace Storage Buckets](https://huggingface.co/docs/hub/storage-buckets) — like AWS S3 for the HuggingFace ecosystem.

Includes a CLI tool (`hfs`) and a programmatic Ruby API.

**No Python dependency. No external CLI calls. 100% Ruby.**

---

## Features

- **Xet CAS Protocol** — Full implementation of the Xet Content-Addressable Storage protocol in pure Ruby: CDC Gearhash chunking, Blake3 keyed hashing (via Fiddle FFI), Xorb and Shard binary formats, iterative Xorb Hash Tree
- **Smart Batching** — Directory uploads batch small files (≤100 MB) into shared xorb + shard + single batch call; large files upload individually. 20 small files need ~4 API calls instead of 60+
- **Cross-Repo Copy** — Server-side copy from models, datasets, spaces, or other buckets using `xetHash`. A 3 GB file takes 1 API call — data never passes through the local machine
- **CLI Tool** — `hfs` command with upload, download, copy, delete, move, list, info, snapshot, and bucket management
- **Cancel Tokens** — Cooperative cancellation for long-running operations (upload, download, batch, copy)
- **Lazy File Handles** — `XetLazyFile` for deferred downloads with metadata-first access pattern
- **Snapshot Downloads** — Directory downloads with JSON manifest for integrity verification
- **File Editing** — In-place remote file edits without download/upload cycle
- **Exclude Patterns** — Glob-based file exclusion for uploads and copies (`*.log`, `*.tmp`, etc.)
- **Glob Upload** — Upload files matching a pattern (`./data/*.csv`)
- **Retry Logic** — Automatic retries for transient HTTP errors (429, 500, 502, 503, 504) and network exceptions with exponential backoff
- **HTTP Debug Logging** — Configurable request/response logging with automatic masking of sensitive headers (Authorization, Cookie, x-xet-access-token)

---

## Installation

Add to your Gemfile:

```ruby
gem "hugging_face_storage"
```

Set your HuggingFace token:

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

---

## CLI Usage

The CLI binary is `bin/hfs`:

```bash
# Upload a directory
bin/hfs upload user/my-bucket ./models/qwen models/qwen

# Download a file
bin/hfs download user/my-bucket models/config.json ./config.json

# Copy from a HuggingFace model (server-side, no data transfer)
bin/hfs copy user/my-bucket tokenizer models/qwen/tokenizer \
  --from_repo "model:Qwen/Qwen2.5-0.5B-Instruct"

# List files
bin/hfs list user/my-bucket models/ -r --format json

# List with debug logging (see full request/response details)
bin/hfs list user/my-bucket models/ --log-level debug

# Snapshot with verification
bin/hfs snapshot user/my-bucket models/qwen ./qwen-snapshot --verify

# Bucket management
bin/hfs buckets list my-org
bin/hfs buckets info user/my-bucket
```

Full CLI reference: [md-docs/CLI.md](md-docs/CLI.md)

---

## Ruby API — Quick Start

```ruby
require "hugging_face_storage"

client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket"
)
```

### Files

```ruby
# Upload a file
client.files.upload("./model.bin", "models/model.bin")

# Upload bytes directly
client.files.upload_bytes("hello world", "greetings.txt")

# Upload with glob pattern
client.files.upload("./data/*.csv", "data/")

# Upload with exclude patterns
client.files.upload("./project", "project", exclude: ["*.log", "*.tmp"])

# Download to local path
client.files.download("models/config.json", "/tmp/config.json")

# Get a lazy file handle (metadata-first, download on demand)
lazy = client.files.download("models/large.bin")  # no local_path → XetLazyFile
lazy.size          # fetches metadata only
lazy.content       # downloads content on first call, caches
lazy.save_to("/tmp/large.bin")

# Or explicitly
lazy = client.files.open("models/large.bin")

# List files
client.files.list(recursive: true).each do |f|
  puts "#{f.path}  #{f.size} bytes  #{f.xet_hash}"
end

# List with prefix filter
client.files.list(prefix: "models/qwen", recursive: true)

# Check existence
client.files.exists?("models/config.json")  # => true/false

# Get metadata
info = client.files.metadata("models/config.json")
info.path       # => "models/config.json"
info.size       # => 660
info.xet_hash   # => "abc123..."
info.mtime      # => "2026-01-15T10:30:00Z"

# Delete (single or batch)
client.files.delete("old-model.bin")
client.files.delete(["a.txt", "b.txt", "c.txt"])

# Move / rename
client.files.move("old-name.bin", "new-name.bin")
client.files.rename("models/v1/config.json", "models/v2/config.json")

# Copy within bucket
client.files.copy("models/v1/config.json", "models/v2/config.json")

# Edit remote file in-place
client.files.edit("config.json", edits: [
  { type: "replace", old: "\"version\": 1", new: "\"version\": 2" }
])
```

### Directories

```ruby
# Create directory
client.directories.create("models/qwen")

# Upload directory (smart batching)
client.directories.upload("./my_model", "models/my_model")
client.directories.upload("./my_model", "models/my_model", exclude: "*.log")

# Download directory (parallel)
client.directories.download("models/qwen", "/tmp/qwen", parallel: 8)

# List directories
client.directories.list
client.directories.list(prefix: "models")

# Check existence
client.directories.exists?("models/qwen")

# Get directory metadata
info = client.directories.metadata("models/qwen")
info.path        # => "models/qwen"
info.file_count  # => 12
info.total_size  # => 3_500_000

# Delete directory (recursive by default)
client.directories.delete("old-model")

# Move / rename directory
client.directories.move("staging/model", "production/model")
client.directories.rename("v1", "v2")

# Copy within bucket
client.directories.copy("models/v1", "backup/v1")
client.directories.copy(["models/a", "models/b"], "backup")

# Copy from external repo (server-side)
client.directories.copy("tokenizer", "models/qwen/tokenizer",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy from tree file
client.directories.copy_from_tree(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  tree: "tree.json",
  destination_prefix: "models/qwen"
)

# Copy entire repo (auto-list + classify + copy/download)
client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "moonshotai/MoonViT-SO-400M",
  destination_prefix: "models/moonvit"
)

# Copy from multiple folders
client.directories.copy_folders(
  folders: [
    { source_type: "model",  source_repo: "org/model-a", source_path: "tokenizer/", destination: "models/a/" },
    { source_type: "dataset", source_repo: "org/data-b",  source_path: "data/",      destination: "data/backup/" }
  ]
)

# Snapshot download with manifest
result = client.directories.snapshot_download("models/qwen", "/tmp/qwen-snap", verify: true)
result[:manifest_path]  # => "/tmp/qwen-snap/.huggingface_snapshot.json"
```

### Cross-Repo File Copy

```ruby
# Single file from model
client.files.copy_file(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "config.json",
  destination: "models/qwen/config.json"
)

# Batch copy from multiple repos
client.files.copy_files(
  files: [
    { source_type: "model", source_repo: "org/a", source_path: "config.json", destination: "a/config.json" },
    { source_type: "dataset", source_repo: "org/b", source_path: "data.csv", destination: "b/data.csv" }
  ]
)

# Batch cross-copy with xetHash
client.files.copy_from(
  source_type: "model",
  source_repo: "org/model",
  files: [
    { xet_hash: "abc123", destination: "models/config.json" }
  ]
)
```

### Bucket Management

```ruby
# Get bucket info
client.bucket_info  # => { "name" => "...", "size" => ... }

# List buckets in namespace
client.list_buckets
client.list_buckets(namespace: "other-org")
```

### Cancel Tokens

```ruby
token = HuggingFaceStorage::CancelToken.new

# Pass to any long-running operation
thread = Thread.new do
  client.directories.upload("./large-model", "models/large", cancel_token: token)
end

# Cancel from another thread
token.cancel!

# Register callbacks
token.on_cancel { puts "Operation was cancelled" }

# Check status
token.cancelled?  # => true/false
```

### Batch Results

Operations that affect multiple files return a `BatchResult`:

```ruby
result = client.files.delete(["a.txt", "b.txt", "c.txt"])
result.success?        # => true/false
result.succeeded       # => [{ type: "deleteFile", path: "a.txt" }, ...]
result.failed          # => [{ path: "b.txt", error: "conflict" }]
result.success_count   # => 2
result.failure_count   # => 1
```

### Logging

```ruby
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "user", bucket: "bucket",
  log_level: :debug,          # :debug, :info, :warn, :error, :fatal
  log_format: :default,       # :default, :plain, :json, :short, or Proc
  log_output: "app.log",      # $stdout, $stderr, StringIO, file path, or writable object
  log_color: :auto            # :auto, true, false
)

# Change at runtime
client.log_level = :warn
client.log_format = :json
```

---

## Error Handling

```ruby
begin
  client.files.download("missing.bin", "/tmp/out")
rescue HuggingFaceStorage::NotFoundError => e
  puts "File not found: #{e.message}"
rescue HuggingFaceStorage::AuthenticationError => e
  puts "Auth failed: #{e.message}"
rescue HuggingFaceStorage::ConflictError => e
  puts "Conflict: #{e.message}"
rescue HuggingFaceStorage::ApiError => e
  puts "API error (HTTP #{e.status}): #{e.body}"
rescue HuggingFaceStorage::CancelledError
  puts "Operation was cancelled"
rescue HuggingFaceStorage::PartialFailureError => e
  puts "#{e.result.failure_count} operation(s) failed"
  e.result.failed.each { |f| puts "  #{f[:path]}: #{f[:error]}" }
end
```

**Error hierarchy:**

```
HuggingFaceStorage::Error
├── AuthenticationError       # HTTP 401, 403
├── NotFoundError             # HTTP 404
├── ConflictError             # HTTP 409
├── ApiError                  # Other HTTP errors (has .status, .body)
├── CancelledError            # CancelToken triggered
└── PartialFailureError       # Batch operation partial failure (has .result)
```

---

## Architecture

```
HuggingFaceStorage
├── Client                       ← Entry point, orchestrator
│   ├── FileManager              ← File facade (delegates to services below)
│   │   ├── FileUploadService    ← File upload (local, bytes, glob, exclude)
│   │   ├── FileDeleteService    ← File deletion (single, batch)
│   │   ├── FileCopyService      ← File copy (same-bucket, cross-repo, CopyPipeline)
│   │   ├── FileEditor           ← In-place remote file editing
│   │   └── FileDownloader       ← File download, XetLazyFile creation
│   ├── DirectoryManager         ← Directory facade (delegates to services below)
│   │   ├── DirectoryCrudService ← Directory CRUD (create, delete, list, move)
│   │   ├── DirectoryTransferService ← Upload/download/snapshot
│   │   ├── DirectoryCopyService ← Directory copy operations
│   │   └── MetadataCache        ← Existence/listing cache
│   ├── ApiClient                ← HTTP wrapper (composition-based)
│   │   ├── HttpPool             ← Thread-safe HTTP connection pool
│   │   ├── Retryable            ← Retry logic (429/5xx, exponential backoff)
│   │   ├── RedirectFollower     ← Xet redirect chain handling
│   │   ├── RequestLogger        ← HTTP request/response debug logging
│   │   ├── BatchHandler         ← Batch API operation dispatch
│   │   └── PaginationService    ← Paginated listing
│   ├── XetStorage               ← Xet CAS protocol
│   │   ├── XetHasher            ← CDC gearhash + Blake3 hashing
│   │   ├── XetSerializer        ← Xorb/Shard binary serialization
│   │   ├── XetStreamProcessor   ← Streaming CDC upload
│   │   ├── XetUploader          ← Xet file upload
│   │   ├── XetDownloader        ← Xet file download
│   │   ├── XetDataUploader      ← Raw data upload
│   │   ├── XetTokenManager      ← Token refresh for Xet operations
│   │   └── CasClient            ← CAS protocol client
│   ├── SameBucketCopyService    ← Same-bucket Xet copy
│   ├── CrossRepoCopyService     ← Cross-repo Xet copy
│   ├── CopyPipeline             ← Batch cross-copy orchestration
│   ├── CopyPlanBuilder          ← Plan server-side copy operations
│   ├── RepoFileCopier           ← Download + re-upload for non-xet files
│   ├── Authentication           ← Token management
│   ├── HFLogger                 ← Configurable logging
│   │   ├── Color                ← ANSI color constants + strip
│   │   ├── StripIO              ← ANSI strip wrapper
│   │   ├── TeeIO                ← Multi-output IO tee
│   │   └── NullLogger           ← No-op logger
│   ├── Instrumentation          ← Metrics + notifications mixin
│   │   ├── MetricsRegistry      ← Prometheus-style counters/histograms
│   │   ├── NullMetricsRegistry  ← No-op metrics
│   │   ├── Notifications        ← Publish/subscribe event system
│   │   └── NullNotifications    ← No-op notifications
│   └── Configuration            ← All config (7 sub-config structs)
│       ├── HttpConfig           ← Timeouts, proxy, max_redirects
│       ├── RetryConfig          ← Retries, backoff, retryable statuses
│       ├── BatchConfig          ← Batch sizes
│       ├── LogConfig            ← Log level, format, colorize
│       ├── CacheConfig          ← Cache TTLs, max entries
│       ├── ParallelConfig       ← Thread counts
│       └── EditConfig           ← Edit patch sizes
│
├── XetLazyFile           ← Lazy file handle (metadata-first, download on demand)
├── CancelToken           ← Cooperative cancellation (thread-safe)
├── BatchResult           ← Track succeeded/failed operations (thread-safe)
├── Snapshot              ← Directory snapshot with JSON manifest
├── DirectoryUploader     ← Smart batch/individual upload by file size
├── DirectoryDownloader   ← Parallel directory download
├── Blake3Pool            ← Thread-local Blake3 hash contexts
├── Blake3Binding         ← Fiddle FFI to libblake3
├── Blake3Buffers         ← Thread-local IOBuffer pool
├── CdcChunker            ← CDC gearhash chunking
├── GearhashTable         ← Precomputed gearhash table
│
├── EntryClassifier       ← Classify files: xet-copy, LFS (error), download
├── ExcludeMatcher        ← Glob pattern matching for file exclusion
├── LfsGuard              ← Validate LFS files are migrated to xet
├── TreeLoader            ← Load tree from Array or JSON file
├── BucketQuery           ← Shared bucket paths-info API queries
├── ApiPaths              ← Centralized HuggingFace API path constants
├── Paths                 ← Path normalization utilities
├── TokenRetryable        ← Token refresh + retry wrapper
├── CLIFormatter          ← CLI output formatting
└── Utils                 ← human_size, hash_to_hex
```

**Dependencies:** `digest-blake3` (~> 1.5), `thor` (~> 1.3)

---

## Project Structure

```
├── src/
│   ├── hugging_face_storage.rb              # Entry point + autoload
│   └── hugging_face_storage/
│       ├── version.rb                       # VERSION = "1.0.0"
│       ├── errors.rb                        # Error hierarchy (7 error classes)
│       ├── authentication.rb                # Token management (HF_TOKEN env)
│       ├── http_pool.rb                     # Thread-safe HTTP connection pool
│       ├── utils.rb                         # human_size, hash_to_hex
│       ├── paths.rb                         # Path normalization
│       ├── lfs_guard.rb                     # LFS file validation
│       ├── exclude_matcher.rb               # Glob pattern exclusion
│       ├── local_file_collector.rb          # File collection with excludes
│       ├── bucket_query.rb                  # Bucket paths-info queries
│       ├── entry_classifier.rb              # File classification (xet/LFS/download)
│       ├── tree_loader.rb                   # Tree from Array or JSON file
│       ├── api_client.rb                    # HTTP client (composition-based)
│       ├── api_paths.rb                     # Centralized API path constants
│       ├── http_pool.rb                     # Thread-safe HTTP connection pool
│       ├── retryable.rb                     # Retry logic with backoff
│       ├── redirect_follower.rb             # Xet redirect chain handler
│       ├── request_logger.rb                # HTTP debug logging
│       ├── batch_handler.rb                 # Batch API dispatch
│       ├── pagination_service.rb            # Paginated API listing
│       ├── file_downloader.rb               # File download + XetLazyFile
│       ├── instrumentation.rb               # Metrics/notifications mixin
│       ├── metrics_registry.rb              # Prometheus-style counters
│       ├── null_metrics_registry.rb         # No-op metrics
│       ├── notifications.rb                 # Publish/subscribe events
│       ├── null_notifications.rb            # No-op notifications
│       ├── token_retryable.rb               # Token refresh + retry
│       ├── configuration.rb                 # All config (7 sub-config structs)
│       ├── xet_hasher.rb                    # Blake3 hashing + CDC gearhash chunking
│       ├── xet_serializer.rb                # Xorb/Shard binary format serialization
│       ├── xet_stream_processor.rb          # Streaming CDC upload processor
│       ├── xet_data_uploader.rb             # Xet data upload
│       ├── xet_uploader.rb                  # Xet file upload
│       ├── xet_downloader.rb                # Xet file download
│       ├── xet_token_manager.rb             # Xet token refresh
│       ├── cas_client.rb                    # CAS protocol client
│       ├── same_bucket_copy_service.rb      # Same-bucket Xet copy
│       ├── cross_repo_copy_service.rb       # Cross-repo Xet copy
│       ├── copy_pipeline.rb                 # Batch cross-copy orchestration
│       ├── repo_file_copier.rb              # Download + upload for non-xet files
│       ├── file_info.rb                     # FileInfo value object
│       ├── xet_lazy_file.rb                 # Lazy file handle
│       ├── file_upload_service.rb           # File upload service
│       ├── file_delete_service.rb           # File deletion service
│       ├── file_copy_service.rb             # File copy service
│       ├── file_editor.rb                   # Remote file editing
│       ├── file_manager.rb                  # File facade
│       ├── directory_crud_service.rb        # Directory CRUD service
│       ├── directory_transfer_service.rb    # Directory upload/download service
│       ├── directory_copy_service.rb        # Directory copy service
│       ├── metadata_cache.rb                # Existence/listing cache
│       ├── directory_downloader.rb          # Parallel directory download
│       ├── directory_uploader.rb            # Smart batch/individual upload
│       ├── directory_manager.rb             # Directory facade
│       ├── batch_result.rb                  # Batch operation result tracking
│       ├── cancel_token.rb                  # Cooperative cancellation
│       ├── snapshot.rb                      # Directory snapshot + manifest
│       ├── logger.rb                        # HFLogger
│       ├── logger/                          # Logger sub-modules
│       │   ├── color.rb                     # ANSI color constants
│       │   ├── io_helpers.rb                # StripIO, TeeIO
│       │   └── null_logger.rb               # No-op logger
│       ├── cli.rb                           # Thor CLI
│       ├── cli_formatter.rb                 # CLI output formatting
│       ├── client.rb                        # Orchestrator
│       ├── copy_plan_builder.rb             # Server-side copy plan builder
│       ├── dir_info.rb                      # DirInfo value object
│       ├── blake3_pool.rb                   # Thread-local Blake3 contexts
│       ├── blake3_binding.rb                # Fiddle FFI to libblake3
│       ├── cdc_chunker.rb                   # CDC gearhash chunker
│       └── gearhash_table.rb                # Precomputed gearhash table
├── spec/                                    # 1700 RSpec test cases
├── bin/
│   ├── hfs                                  # CLI binary
│   ├── rspec                                # RSpec binstub
│   └── rake                                 # Rake binstub
├── md-docs/
│   ├── CLI.md                               # CLI reference (EN)
│   └── CLI.vi.md                            # CLI reference (VI)
├── examples/
│   ├── usage.rb                             # Runnable examples (EN)
│   └── usage.vi.rb                          # Runnable examples (VI)
├── .github/workflows/ci.yml                 # CI workflow
├── Gemfile                                  # digest-blake3 + thor + rspec + webmock
├── Rakefile                                 # rake spec
├── .rspec                                   # RSpec config
└── LICENSE                                  # MIT
```

---

## Testing

```bash
# Run all tests
rake

# Run via rspec directly
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/hugging_face_storage/xet_storage_spec.rb

# Run tests matching a pattern
bundle exec rspec --example "blake3"
```

**1700 test cases** — **99.79% line coverage** — covering:

- Authentication, Logger, Error classes, Paths, Utils
- ApiClient (HTTP methods, pagination, retry, error handling, streaming, sensitive header masking)
- XetStorage (CDC chunking, Blake3 hashing, xorb/shard serialization, upload/download)
- FileManager (upload, download, delete, move, copy, list, metadata, exists, edit, glob, cross-repo)
- FileUploadService, FileDeleteService, FileCopyService
- DirectoryManager (create, delete, upload, download, copy, copy_from_tree, copy_from_repo, copy_folders, cross-repo, snapshot)
- DirectoryCrudService, DirectoryTransferService, DirectoryCopyService
- DirectoryUploader, DirectoryDownloader, RepoFileCopier, CopyPlanBuilder
- Configuration (all 7 sub-config structs with backward-compatible delegates)
- CancelToken, BatchResult, Snapshot, XetLazyFile
- CLI (all commands), CLIFormatter
- Client (initialization, bucket_info, list_buckets, log_level)

All HTTP requests are mocked with WebMock — **no real API calls during tests**.

---

## Documentation

| Document | Content |
|----------|---------|
| [CLI Reference (EN)](md-docs/CLI.md) | CLI command reference |
| [Code Examples](examples/usage.rb) | Runnable Ruby file with full use cases |

---

## Requirements

- **Ruby** >= 2.7
- **HuggingFace account** with a Storage Bucket created

---

## License

[MIT](LICENSE)
