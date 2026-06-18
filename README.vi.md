# HuggingFace Storage — Ruby Client

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

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

Thư viện Ruby thuần để quản lý file trong [HuggingFace Storage Buckets](https://huggingface.co/docs/hub/storage-buckets) — giống như AWS S3 dành cho hệ sinh thái HuggingFace.

Bao gồm công cụ CLI (`hfs`) và API Ruby lập trình được.

**Không phụ thuộc Python. Không gọi CLI ngoài. 100% Ruby.**

---

## Tính năng

- **Giao thức Xet CAS** — Triển khai đầy đủ giao thức Xet Content-Addressable Storage trong Ruby thuần: phân đoạn CDC Gearhash, băm khóa Blake3 (qua Fiddle FFI), định dạng nhị phân Xorb và Shard, cây băm Xorb lặp
- **Smart Batching** — Upload thư mục gộp các file nhỏ (≤100 MB) vào một xorb + shard + một lệnh gọi batch duy nhất; các file lớn được upload riêng lẻ. 20 file nhỏ chỉ cần ~4 lệnh gọi API thay vì 60+
- **Cross-Repo Copy** — Copy phía máy chủ từ model, dataset, space hoặc bucket khác dùng `xetHash`. File 3 GB chỉ cần 1 lệnh gọi API — dữ liệu không bao giờ đi qua máy local
- **CLI Tool** — Lệnh `hfs` với upload, download, copy, delete, move, list, info, snapshot và quản lý bucket
- **Cancel Tokens** — Hủy hợp tác cho các tác vụ chạy lâu (upload, download, batch, copy)
- **Lazy File Handles** — `XetLazyFile` cho download trì hoãn với mô hình truy cập metadata trước
- **Snapshot Downloads** — Download thư mục với JSON manifest để xác minh tính toàn vẹn
- **File Editing** — Chỉnh sửa file từ xa tại chỗ không cần chu kỳ download/upload
- **Exclude Patterns** — Loại trừ file dựa trên glob pattern cho upload và copy (`*.log`, `*.tmp`, v.v.)
- **Glob Upload** — Upload file khớp với pattern (`./data/*.csv`)
- **Retry Logic** — Tự động thử lại cho lỗi HTTP tạm thời (429, 500, 502, 503, 504) và ngoại lệ mạng với exponential backoff
- **HTTP Debug Logging** — Ghi log request/response có thể cấu hình với tự động che giấu header nhạy cảm (Authorization, Cookie, x-xet-access-token)

---

## Cài đặt

Thêm vào Gemfile của bạn:

```ruby
gem "hugging_face_storage"
```

Đặt token HuggingFace của bạn:

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

---

## CLI Usage

CLI binary là `bin/hfs`:

```bash
# Upload thư mục
bin/hfs upload user/my-bucket ./models/qwen models/qwen

# Download file
bin/hfs download user/my-bucket models/config.json ./config.json

# Copy từ HuggingFace model (phía máy chủ, không truyền dữ liệu)
bin/hfs copy user/my-bucket tokenizer models/qwen/tokenizer \
  --from_repo "model:Qwen/Qwen2.5-0.5B-Instruct"

# Liệt kê file
bin/hfs list user/my-bucket models/ -r --format json

# Liệt kê với debug logging (xem chi tiết request/response)
bin/hfs list user/my-bucket models/ --log-level debug

# Snapshot với xác minh
bin/hfs snapshot user/my-bucket models/qwen ./qwen-snapshot --verify

# Quản lý bucket
bin/hfs buckets list my-org
bin/hfs buckets info user/my-bucket
```

Tài liệu CLI đầy đủ: [md-docs/CLI.vi.md](md-docs/CLI.vi.md)

---

## Ruby API — Bắt đầu nhanh

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
# Upload file
client.files.upload("./model.bin", "models/model.bin")

# Upload bytes trực tiếp
client.files.upload_bytes("hello world", "greetings.txt")

# Upload với glob pattern
client.files.upload("./data/*.csv", "data/")

# Upload với exclude patterns
client.files.upload("./project", "project", exclude: ["*.log", "*.tmp"])

# Download đến đường dẫn local
client.files.download("models/config.json", "/tmp/config.json")

# Lấy lazy file handle (metadata trước, download theo yêu cầu)
lazy = client.files.download("models/large.bin")  # không có local_path → XetLazyFile
lazy.size          # lấy metadata chỉ
lazy.content       # download nội dung ở lần gọi đầu, lưu cache
lazy.save_to("/tmp/large.bin")

# Hoặc khởi tạo tường minh
lazy = client.files.open("models/large.bin")

# Liệt kê file
client.files.list(recursive: true).each do |f|
  puts "#{f.path}  #{f.size} bytes  #{f.xet_hash}"
end

# Liệt kê với bộ lọc prefix
client.files.list(prefix: "models/qwen", recursive: true)

# Kiểm tra tồn tại
client.files.exists?("models/config.json")  # => true/false

# Lấy metadata
info = client.files.metadata("models/config.json")
info.path       # => "models/config.json"
info.size       # => 660
info.xet_hash   # => "abc123..."
info.mtime      # => "2026-01-15T10:30:00Z"

# Xóa (đơn hoặc hàng loạt)
client.files.delete("old-model.bin")
client.files.delete(["a.txt", "b.txt", "c.txt"])

# Di chuyển / đổi tên
client.files.move("old-name.bin", "new-name.bin")
client.files.rename("models/v1/config.json", "models/v2/config.json")

# Copy trong cùng bucket
client.files.copy("models/v1/config.json", "models/v2/config.json")

# Chỉnh sửa file từ xa tại chỗ
client.files.edit("config.json", edits: [
  { type: "replace", old: "\"version\": 1", new: "\"version\": 2" }
])
```

### Directories

```ruby
# Tạo thư mục
client.directories.create("models/qwen")

# Upload thư mục (smart batching)
client.directories.upload("./my_model", "models/my_model")
client.directories.upload("./my_model", "models/my_model", exclude: "*.log")

# Download thư mục (song song)
client.directories.download("models/qwen", "/tmp/qwen", parallel: 8)

# Liệt kê thư mục
client.directories.list
client.directories.list(prefix: "models")

# Kiểm tra tồn tại
client.directories.exists?("models/qwen")

# Lấy metadata thư mục
info = client.directories.metadata("models/qwen")
info.path        # => "models/qwen"
info.file_count  # => 12
info.total_size  # => 3_500_000

# Xóa thư mục (đệ quy theo mặc định)
client.directories.delete("old-model")

# Di chuyển / đổi tên thư mục
client.directories.move("staging/model", "production/model")
client.directories.rename("v1", "v2")

# Copy trong cùng bucket
client.directories.copy("models/v1", "backup/v1")
client.directories.copy(["models/a", "models/b"], "backup")

# Copy từ repo bên ngoài (phía máy chủ)
client.directories.copy("tokenizer", "models/qwen/tokenizer",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy từ tree file
client.directories.copy_from_tree(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  tree: "tree.json",
  destination_prefix: "models/qwen"
)

# Copy toàn bộ repo (tự động liệt kê + phân loại + copy/download)
client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "moonshotai/MoonViT-SO-400M",
  destination_prefix: "models/moonvit"
)

# Copy từ nhiều thư mục
client.directories.copy_folders(
  folders: [
    { source_type: "model",  source_repo: "org/model-a", source_path: "tokenizer/", destination: "models/a/" },
    { source_type: "dataset", source_repo: "org/data-b",  source_path: "data/",      destination: "data/backup/" }
  ]
)

# Snapshot download với manifest
result = client.directories.snapshot_download("models/qwen", "/tmp/qwen-snap", verify: true)
result[:manifest_path]  # => "/tmp/qwen-snap/.huggingface_snapshot.json"
```

### Cross-Repo File Copy

```ruby
# File đơn lẻ từ model
client.files.copy_file(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "config.json",
  destination: "models/qwen/config.json"
)

# Batch copy từ nhiều repo
client.files.copy_files(
  files: [
    { source_type: "model", source_repo: "org/a", source_path: "config.json", destination: "a/config.json" },
    { source_type: "dataset", source_repo: "org/b", source_path: "data.csv", destination: "b/data.csv" }
  ]
)

# Batch cross-copy với xetHash
client.files.copy_from(
  source_type: "model",
  source_repo: "org/model",
  files: [
    { xet_hash: "abc123", destination: "models/config.json" }
  ]
)
```

### Quản lý Bucket

```ruby
# Lấy thông tin bucket
client.bucket_info  # => { "name" => "...", "size" => ... }

# Liệt kê bucket trong namespace
client.list_buckets
client.list_buckets(namespace: "other-org")
```

### Cancel Tokens

```ruby
token = HuggingFaceStorage::CancelToken.new

# Truyền vào bất kỳ tác vụ chạy lâu nào
thread = Thread.new do
  client.directories.upload("./large-model", "models/large", cancel_token: token)
end

# Hủy từ thread khác
token.cancel!

# Đăng ký callback
token.on_cancel { puts "Thao tác đã bị hủy" }

# Kiểm tra trạng thái
token.cancelled?  # => true/false
```

### Batch Results

Các thao tác ảnh hưởng đến nhiều file trả về `BatchResult`:

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
  log_format: :default,       # :default, :plain, :json, :short, hoặc Proc
  log_output: "app.log",      # $stdout, $stderr, StringIO, đường dẫn file, hoặc đối tượng writable
  log_color: :auto            # :auto, true, false
)

# Thay đổi tại runtime
client.log_level = :warn
client.log_format = :json
```

---

## Xử lý lỗi

```ruby
begin
  client.files.download("missing.bin", "/tmp/out")
rescue HuggingFaceStorage::NotFoundError => e
  puts "Không tìm thấy file: #{e.message}"
rescue HuggingFaceStorage::AuthenticationError => e
  puts "Xác thực thất bại: #{e.message}"
rescue HuggingFaceStorage::ConflictError => e
  puts "Xung đột: #{e.message}"
rescue HuggingFaceStorage::ApiError => e
  puts "Lỗi API (HTTP #{e.status}): #{e.body}"
rescue HuggingFaceStorage::CancelledError
  puts "Thao tác đã bị hủy"
rescue HuggingFaceStorage::PartialFailureError => e
  puts "#{e.result.failure_count} thao tác thất bại"
  e.result.failed.each { |f| puts "  #{f[:path]}: #{f[:error]}" }
end
```

**Phân cấp lỗi:**

```
HuggingFaceStorage::Error
├── AuthenticationError       # HTTP 401, 403
├── NotFoundError             # HTTP 404
├── ConflictError             # HTTP 409
├── ApiError                  # Lỗi HTTP khác (có .status, .body)
├── CancelledError            # CancelToken được kích hoạt
└── PartialFailureError       # Thao tác batch thất bại một phần (có .result)
```

---

## Kiến trúc

```
HuggingFaceStorage
├── Client                       ← Điểm vào, điều phối
│   ├── FileManager              ← File facade (ủy quyền cho các service bên dưới)
│   │   ├── FileUploadService    ← Upload file (local, bytes, glob, exclude)
│   │   ├── FileDeleteService    ← Xóa file (đơn, hàng loạt)
│   │   ├── FileCopyService      ← Copy file (cùng bucket, cross-repo, CopyPipeline)
│   │   ├── FileEditor           ← Chỉnh sửa file từ xa tại chỗ
│   │   └── FileDownloader       ← Download file, tạo XetLazyFile
│   ├── DirectoryManager         ← Directory facade (ủy quyền cho các service bên dưới)
│   │   ├── DirectoryCrudService ← CRUD thư mục (create, delete, list, move)
│   │   ├── DirectoryTransferService ← Upload/download/snapshot
│   │   ├── DirectoryCopyService ← Copy thư mục
│   │   └── MetadataCache        ← Cache tồn tại/liệt kê
│   ├── ApiClient                ← HTTP wrapper (composition-based)
│   │   ├── HttpPool             ← Pool kết nối HTTP thread-safe
│   │   ├── Retryable            ← Retry logic (429/5xx, exponential backoff)
│   │   ├── RedirectFollower     ← Xử lý chuỗi chuyển hướng Xet
│   │   ├── RequestLogger        ← Ghi log request/response HTTP debug
│   │   ├── BatchHandler         ← Điều phối thao tác batch API
│   │   └── PaginationService    ← Liệt kê phân trang
│   ├── XetStorage               ← Giao thức Xet CAS
│   │   ├── XetHasher            ← CDC gearhash + băm Blake3
│   │   ├── XetSerializer        ← Tuần tự hóa nhị phân Xorb/Shard
│   │   ├── XetStreamProcessor   ← Upload CDC streaming
│   │   ├── XetUploader          ← Upload file Xet
│   │   ├── XetDownloader        ← Download file Xet
│   │   ├── XetDataUploader      ← Upload dữ liệu thô
│   │   ├── XetTokenManager      ← Làm mới token cho thao tác Xet
│   │   └── CasClient            ← Client giao thức CAS
│   ├── SameBucketCopyService    ← Copy Xet cùng bucket
│   ├── CrossRepoCopyService     ← Copy Xet cross-repo
│   ├── CopyPipeline             ← Điều phối batch cross-copy
│   ├── CopyPlanBuilder          ← Lập kế hoạch copy server-side
│   ├── RepoFileCopier           ← Download + upload lại cho file không xet
│   ├── Authentication           ← Quản lý token
│   ├── HFLogger                 ← Logging có thể cấu hình
│   │   ├── Color                ← Hằng số màu ANSI + strip
│   │   ├── StripIO              ← Bọc ANSI strip
│   │   ├── TeeIO                ← IO tee đa đầu ra
│   │   └── NullLogger           ← Logger không làm gì
│   ├── Instrumentation          ← Mixin metrics + thông báo
│   │   ├── MetricsRegistry      ← Counter/histogram kiểu Prometheus
│   │   ├── NullMetricsRegistry  ← Metrics không làm gì
│   │   ├── Notifications        ← Hệ thống sự kiện publish/subscribe
│   │   └── NullNotifications    ← Thông báo không làm gì
│   └── Configuration            ← Toàn bộ cấu hình (7 sub-config struct)
│       ├── HttpConfig           ← Timeout, proxy, max_redirects
│       ├── RetryConfig          ← Số lần thử lại, backoff, trạng thái thử lại
│       ├── BatchConfig          ← Kích thước batch
│       ├── LogConfig            ← Mức log, định dạng, màu sắc
│       ├── CacheConfig          ← TTL cache, số mục tối đa
│       ├── ParallelConfig       ← Số luồng
│       └── EditConfig           ← Kích thước patch chỉnh sửa
│
├── XetLazyFile           ← Lazy file handle (metadata trước, download theo yêu cầu)
├── CancelToken           ← Hủy hợp tác (thread-safe)
├── BatchResult           ← Theo dõi thao tác thành công/thất bại (thread-safe)
├── Snapshot              ← Snapshot thư mục với JSON manifest
├── DirectoryUploader     ← Upload batch/cá nhân thông minh theo kích thước file
├── DirectoryDownloader   ← Download thư mục song song
├── Blake3Pool            ← Ngữ cảnh băm Blake3 theo thread
├── Blake3Binding         ← Fiddle FFI tới libblake3
├── Blake3Buffers         ← Pool IOBuffer theo thread
├── CdcChunker            ← Phân đoạn CDC gearhash
├── GearhashTable         ← Bảng gearhash tính sẵn
│
├── EntryClassifier       ← Phân loại file: xet-copy, LFS (lỗi), download
├── ExcludeMatcher        ← So khớp glob pattern để loại trừ file
├── LfsGuard              ← Xác thực file LFS đã được di chuyển sang xet
├── TreeLoader            ← Tải tree từ Array hoặc file JSON
├── BucketQuery           ← Truy vấn API paths-info bucket dùng chung
├── ApiPaths              ← Hằng số đường dẫn API HuggingFace tập trung
├── Paths                 ← Tiện ích chuẩn hóa đường dẫn
├── TokenRetryable        ← Bọc làm mới token + thử lại
├── CLIFormatter          ← Định dạng đầu ra CLI
└── Utils                 ← human_size, hash_to_hex
```

**Phụ thuộc:** `digest-blake3` (~> 1.5), `thor` (~> 1.3)

---

## Cấu trúc dự án

```
├── src/
│   ├── hugging_face_storage.rb              # Điểm vào + autoload
│   └── hugging_face_storage/
│       ├── version.rb                       # VERSION = "1.0.0"
│       ├── errors.rb                        # Phân cấp lỗi (7 lớp lỗi)
│       ├── authentication.rb                # Quản lý token (HF_TOKEN env)
│       ├── http_pool.rb                     # Pool kết nối HTTP thread-safe
│       ├── utils.rb                         # human_size, hash_to_hex
│       ├── paths.rb                         # Chuẩn hóa đường dẫn
│       ├── lfs_guard.rb                     # Xác thực file LFS
│       ├── exclude_matcher.rb               # Loại trừ glob pattern
│       ├── local_file_collector.rb          # Thu thập file với excludes
│       ├── bucket_query.rb                  # Truy vấn bucket paths-info
│       ├── entry_classifier.rb              # Phân loại file (xet/LFS/download)
│       ├── tree_loader.rb                   # Tree từ Array hoặc file JSON
│       ├── api_client.rb                    # HTTP client (composition-based)
│       ├── api_paths.rb                     # Hằng số đường dẫn API tập trung
│       ├── http_pool.rb                     # Pool kết nối HTTP thread-safe
│       ├── retryable.rb                     # Retry logic với backoff
│       ├── redirect_follower.rb             # Xử lý chuỗi chuyển hướng Xet
│       ├── request_logger.rb                # Ghi log HTTP debug
│       ├── batch_handler.rb                 # Điều phối batch API
│       ├── pagination_service.rb            # Liệt kê API phân trang
│       ├── file_downloader.rb               # Download file + XetLazyFile
│       ├── instrumentation.rb               # Mixin metrics/thông báo
│       ├── metrics_registry.rb              # Counter kiểu Prometheus
│       ├── null_metrics_registry.rb         # Metrics không làm gì
│       ├── notifications.rb                 # Sự kiện publish/subscribe
│       ├── null_notifications.rb            # Thông báo không làm gì
│       ├── token_retryable.rb               # Làm mới token + thử lại
│       ├── configuration.rb                 # Toàn bộ cấu hình (7 sub-config)
│       ├── xet_hasher.rb                    # Băm Blake3 + phân đoạn CDC gearhash
│       ├── xet_serializer.rb                # Tuần tự hóa nhị phân Xorb/Shard
│       ├── xet_stream_processor.rb          # Xử lý upload CDC streaming
│       ├── xet_data_uploader.rb             # Upload dữ liệu Xet
│       ├── xet_uploader.rb                  # Upload file Xet
│       ├── xet_downloader.rb                # Download file Xet
│       ├── xet_token_manager.rb             # Làm mới token Xet
│       ├── cas_client.rb                    # Client giao thức CAS
│       ├── same_bucket_copy_service.rb      # Copy Xet cùng bucket
│       ├── cross_repo_copy_service.rb       # Copy Xet cross-repo
│       ├── copy_pipeline.rb                 # Điều phối batch cross-copy
│       ├── repo_file_copier.rb              # Download + upload cho file không xet
│       ├── file_info.rb                     # FileInfo value object
│       ├── xet_lazy_file.rb                 # Lazy file handle
│       ├── file_upload_service.rb           # Service upload file
│       ├── file_delete_service.rb           # Service xóa file
│       ├── file_copy_service.rb             # Service copy file
│       ├── file_editor.rb                   # Chỉnh sửa file từ xa
│       ├── file_manager.rb                  # File facade
│       ├── directory_crud_service.rb        # Service CRUD thư mục
│       ├── directory_transfer_service.rb    # Service upload/download thư mục
│       ├── directory_copy_service.rb        # Service copy thư mục
│       ├── metadata_cache.rb                # Cache tồn tại/liệt kê
│       ├── directory_downloader.rb          # Download thư mục song song
│       ├── directory_uploader.rb            # Upload batch/cá nhân thông minh
│       ├── directory_manager.rb             # Directory facade
│       ├── batch_result.rb                  # Theo dõi kết quả thao tác batch
│       ├── cancel_token.rb                  # Hủy hợp tác
│       ├── snapshot.rb                      # Snapshot thư mục + manifest
│       ├── logger.rb                        # HFLogger
│       ├── logger/                          # Module con của logger
│       │   ├── color.rb                     # Hằng số màu ANSI
│       │   ├── io_helpers.rb                # StripIO, TeeIO
│       │   └── null_logger.rb               # Logger không làm gì
│       ├── cli.rb                           # Thor CLI
│       ├── cli_formatter.rb                 # Định dạng đầu ra CLI
│       ├── client.rb                        # Điều phối
│       ├── copy_plan_builder.rb             # Lập kế hoạch copy server-side
│       ├── dir_info.rb                      # DirInfo value object
│       ├── blake3_pool.rb                   # Ngữ cảnh Blake3 theo thread
│       ├── blake3_binding.rb                # Fiddle FFI tới libblake3
│       ├── cdc_chunker.rb                   # Phân đoạn CDC gearhash
│       └── gearhash_table.rb                # Bảng gearhash tính sẵn
├── spec/                                    # 1700+ test case RSpec
├── bin/
│   ├── hfs                                  # CLI binary
│   ├── rspec                                # RSpec binstub
│   └── rake                                 # Rake binstub
├── md-docs/
│   ├── CLI.md                               # Tài liệu CLI (EN)
│   └── CLI.vi.md                            # Tài liệu CLI (VI)
├── examples/
│   ├── usage.rb                             # Ví dụ chạy được (EN)
│   └── usage.vi.rb                          # Ví dụ chạy được (VI)
├── .github/workflows/ci.yml                 # CI workflow
├── Gemfile                                  # digest-blake3 + thor + rspec + webmock
├── Rakefile                                 # rake spec
├── .rspec                                   # Cấu hình RSpec
└── LICENSE                                  # MIT
```

---

## Kiểm thử

```bash
# Chạy tất cả test
rake

# Chạy qua rspec trực tiếp
bundle exec rspec

# Chạy một file spec
bundle exec rspec spec/hugging_face_storage/xet_storage_spec.rb

# Chạy test khớp với pattern
bundle exec rspec --example "blake3"
```

**1672 test case** — **99.79% line coverage** — bao gồm:

- Authentication, Logger, Error classes, Paths, Utils
- ApiClient (HTTP methods, phân trang, retry, xử lý lỗi, streaming, che giấu header nhạy cảm)
- XetStorage (phân đoạn CDC, băm Blake3, tuần tự hóa xorb/shard, upload/download)
- FileManager (upload, download, delete, move, copy, list, metadata, exists, edit, glob, cross-repo)
- FileUploadService, FileDeleteService, FileCopyService
- DirectoryManager (create, delete, upload, download, copy, copy_from_tree, copy_from_repo, copy_folders, cross-repo, snapshot)
- DirectoryCrudService, DirectoryTransferService, DirectoryCopyService
- DirectoryUploader, DirectoryDownloader, RepoFileCopier, CopyPlanBuilder
- Configuration (toàn bộ 7 sub-config struct với backward-compatible delegates)
- CancelToken, BatchResult, Snapshot, XetLazyFile
- CLI (tất cả lệnh), CLIFormatter
- Client (khởi tạo, bucket_info, list_buckets, log_level)

Tất cả request HTTP đều được mock bằng WebMock — **không gọi API thực trong quá trình test**.

---

## Tài liệu

| Tài liệu | Nội dung |
|----------|----------|
| [CLI Reference (VI)](md-docs/CLI.vi.md) | Tài liệu lệnh CLI |
| [Code Examples](examples/usage.vi.rb) | File Ruby chạy được với đầy đủ use case |

---

## Yêu cầu

- **Ruby** >= 2.7
- **Tài khoản HuggingFace** đã tạo Storage Bucket

---

## Giấy phép

[MIT](LICENSE)
