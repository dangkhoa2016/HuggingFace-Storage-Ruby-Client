# frozen_string_literal: true

# ============================================================
# HuggingFace Storage - Ruby Client Usage Examples
# ============================================================
#
# Yêu cầu:
#   - gem install digest-blake3
#   - export HF_TOKEN=hf_xxx
#
# Chạy:
#   ruby examples/usage.rb

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "hugging_face_storage"

# ============================================================
# KHỞI TẠO CLIENT
# ============================================================

# Cơ bản
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket"
)

# Với logging đầy đủ
# log_level:  :debug | :info | :warn | :error | :fatal
# log_output: $stdout | $stderr | "/path/to/file.log"
# log_format: :default | :short | :plain | :json | Proc
# log_color:  :auto | true | false
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :info,
  log_output: $stdout,
  log_format: :default
)

# Log ra file
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :debug,
  log_output: "/tmp/hf_storage.log",
  log_format: :default
)

# Log format JSON (phù hợp cho log aggregation)
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :info,
  log_format: :json
)
# Output: {"timestamp":"2026-06-05T21:30:00.000+07:00","level":"INFO","message":"..."}

# Log format ngắn gọn
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :info,
  log_format: :short
)
# Output: I 21:30:00 Uploading file: ...

# Log format tùy chỉnh (Proc)
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :debug,
  log_format: ->(time, level, msg, color) { ">> [#{level}] #{msg}" }
)

# Debug mode (giữ lại backtrace trong lỗi)
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  debug_mode: true,
  log_level: :debug
)

# ============================================================
# BUCKET INFO
# ============================================================

# Lấy thông tin bucket hiện tại
info = client.bucket_info
puts "Bucket: #{info["id"]}, files=#{info["totalFiles"]}, size=#{info["size"]}"

# Liệt kê tất cả buckets của user
buckets = client.list_buckets
buckets.each { |b| puts "  #{b["id"]} (#{b["totalFiles"]} files)" }

# ============================================================
# FILE OPERATIONS
# ============================================================

# --- Upload ---

# Upload file từ local
result = client.files.upload("./local_model.bin", "models/model.bin")
puts "Uploaded: #{result.inspect}"

# Upload raw bytes (string)
client.files.upload_bytes("hello world", "notes/readme.txt")

# Upload binary data
binary_data = File.binread("./image.png")
client.files.upload_bytes(binary_data, "images/logo.png")

# --- List ---

# Liệt kê file ở root (non-recursive)
root_files = client.files.list
root_files.each { |f| puts "  #{f.name} (#{f.size} bytes)" }

# Liệt kê file recursive (tất cả file trong bucket)
all_files = client.files.list(recursive: true)
puts "Total files: #{all_files.size}"

# Liệt kê file trong thư mục cụ thể
model_files = client.files.list(prefix: "models/qwen")
model_files.each { |f| puts "  #{f.path} (#{f.size} bytes)" }

# Liệt kê recursive trong thư mục
deep_files = client.files.list(prefix: "models", recursive: true)

# FileInfo attributes
file = model_files.first
puts file.path       # "models/qwen/config.json"
puts file.name       # "config.json"
puts file.directory  # "models/qwen"
puts file.size       # 660
puts file.xet_hash   # "3a1f858c..."
puts file.to_h       # { path:, size:, xet_hash:, mtime: }

# --- Metadata ---

info = client.files.metadata("models/qwen/config.json")
puts "File: #{info.path}, size=#{info.size}, hash=#{info.xet_hash}"

# --- Check existence ---

puts client.files.exists?("models/qwen/config.json")  # true
puts client.files.exists?("nonexistent.txt")           # false

# --- Download ---

client.files.download("models/qwen/config.json", "/tmp/config.json")

# --- Copy (trong cùng bucket) ---

client.files.copy("models/qwen/config.json", "backup/qwen_config.json")

# --- Move / Rename ---

# Di chuyển file
client.files.move("notes/readme.txt", "archive/readme.txt")

# Đổi tên (bản chất là move)
client.files.rename("archive/readme.txt", "archive/readme_v2.txt")

# --- Delete ---

# Xóa 1 file
client.files.delete("archive/readme_v2.txt")

# Xóa nhiều file cùng lúc
client.files.delete(["old/file1.txt", "old/file2.bin", "old/file3.json"])

# Phát hiện thư mục — raise Error kèm hướng dẫn dùng directories.delete:
#   client.files.delete("models/assets")
#   => Error: 'models/assets' is a directory. Use client.directories.delete instead.
#   client.files.delete(["a.txt", "models/assets", "b.txt"])
#   => Error: 'models/assets' is a directory. Use client.directories.delete instead.

# ============================================================
# CROSS-REPO COPY (Server-side, KHÔNG download/upload data)
# ============================================================
#
# Copy file giữa các bucket/model/dataset bằng xetHash.
# Data không di chuyển qua máy local - hoàn toàn server-side.
# Copy file 3GB cũng chỉ mất 1 API call.

# --- Copy single file bằng xetHash ---

client.files.copy_from(
  source_type: "bucket",                          # "bucket" | "model" | "dataset"
  source_repo: "other-user/other-bucket",         # repo ID nguồn
  source_path: "models/config.json",               # path nguồn (cho log)
  xet_hash: "3a1f858c414da4362c5df3e40b110ff313fd2a85b7ee3464a1d48e4ebf5b2114",
  destination: "copied/config.json"                # path đích
)

# Copy từ model repo
client.files.copy_from(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  xet_hash: "<xet_hash_of_config>",
  destination: "models/qwen/config.json"
)

# --- Batch copy nhiều files ---

client.files.copy_from(
  source_type: "bucket",
  source_repo: "other-user/source-bucket",
  files: [
    { xet_hash: "hash_1", destination: "dest/file1.txt" },
    { xet_hash: "hash_2", destination: "dest/file2.json" },
    { xet_hash: "hash_3", destination: "dest/file3.bin" },
  ]
)

# ============================================================
# COPY FILE / FILES (Tự phân loại + xử lý non-xet files)
# ============================================================
#
# API copy cao cấp hơn, tự động phân loại file nguồn:
#   - xet-backed => server-side copy (zero data transfer)
#   - LFS (chưa migrate) => raise Error với danh sách file + kích thước
#   - Regular git file => download + re-upload qua xet
#
# Không giống copy_from (yêu cầu xetHash), copy_file / copy_files
# tự tra cứu metadata và xử lý cả 3 loại.

# --- Copy 1 file từ model/dataset/bucket ---

# xet-backed: server-side copy, không download
client.files.copy_file(
  source_type: "model",
  source_repo: "google/gemma-2-2b",
  source_path: "model.safetensors",
  destination: "models/gemma-2/model.safetensors"
)

# Từ dataset với revision cụ thể
client.files.copy_file(
  source_type: "dataset",
  source_repo: "user/my-dataset",
  source_path: "data/train.csv",
  destination: "datasets/train.csv",
  revision: "v1.0"
)

# File git nhỏ (vd: config.json): tự động download + re-upload
client.files.copy_file(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "config.json",
  destination: "models/qwen/config.json"
)

# Destination kết thúc bằng "/" tự động nối thêm tên file:
# "models/gemma-2/" + "model.safetensors" = "models/gemma-2/model.safetensors"
client.files.copy_file(
  source_type: "model",
  source_repo: "google/gemma-2-2b",
  source_path: "model.safetensors",
  destination: "models/gemma-2/"
)

# Từ bucket khác (revision bị bỏ qua)
client.files.copy_file(
  source_type: "bucket",
  source_repo: "other-user/source-bucket",
  source_path: "backup/data.bin",
  destination: "imported/data.bin"
)

# Với theo dõi tiến trình cho 1 file
client.files.copy_file(
  source_type: "model",
  source_repo: "org/model",
  source_path: "large_weights.bin",
  destination: "models/weights.bin",
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Downloaded #{path} (#{downloaded}/#{total})"
  }
)

# Kiểm soát overwrite (bỏ qua nếu file đích đã tồn tại)
client.files.copy_file(
  source_type: "model",
  source_repo: "org/model",
  source_path: "config.json",
  destination: "models/config.json",
  overwrite: false  # bỏ qua nếu đã tồn tại
)

# --- Copy nhiều file từ các repo khác nhau trong 1 batch ---
#
# Tất cả file được phân loại và xử lý trong 1 batch commit.
# File xet: server-side copy; file git: download + upload.

client.files.copy_files(
  files: [
    # Từ model repo (xet file → server-side copy)
    { source_type: "model",  source_repo: "org/model-a",  source_path: "weights.bin", destination: "models/weights.bin" },
    # Từ dataset (file git nhỏ → download + upload)
    { source_type: "dataset", source_repo: "org/data-b",  source_path: "labels.csv",  destination: "data/labels.csv"   },
    # Từ bucket khác (xet file → server-side)
    { source_type: "bucket",  source_repo: "org/backup",   source_path: "archive.bin", destination: "backup/archive.bin" },
  ]
)

# Với theo dõi tiến trình
client.files.copy_files(
  files: [
    { source_type: "model", source_repo: "org/model-a", source_path: "a.bin", destination: "a.bin" },
    { source_type: "model", source_repo: "org/model-a", source_path: "b.bin", destination: "b.bin" },
  ],
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Downloaded #{path} (#{downloaded}/#{total})"
  }
)

# --- Copy từ tree JSON (tiện ích nhất) ---
#
# Đọc file tree JSON (từ list_bucket_tree / list_repo_tree)
# và copy hàng loạt files server-side.
#
# Tree JSON format:
# [
#   {"type":"file", "path":"models/config.json", "size":660, "xetHash":"3a1f..."},
#   {"type":"file", "path":"models/model.safetensors", "size":3087467144, "xetHash":"46ea..."},
#   ...
# ]


# ============================================================
# DIRECTORY OPERATIONS
# ============================================================

# --- List directories ---

# Thư mục ở root
dirs = client.directories.list
dirs.each { |d| puts "  #{d.path}" }

# Thư mục con
subdirs = client.directories.list(prefix: "deepseek-ai")

# --- Check existence ---

puts client.directories.exists?("models")       # true
puts client.directories.exists?("nonexistent")  # false

# --- List files in directory ---

files = client.directories.list_files("models/qwen", recursive: true)
puts "Files: #{files.size}"

# --- Metadata ---

meta = client.directories.metadata("models/qwen")
puts "Dir: #{meta.path}"
puts "  files=#{meta.file_count}, size=#{meta.total_size}"

# DirInfo attributes
puts meta.name    # "qwen"
puts meta.parent  # "models"
puts meta.to_h    # { path:, file_count:, total_size:, uploaded_at: }

# --- Create directory ---

client.directories.create("new_folder")
client.directories.create("deep/nested/folder")

# --- Download directory ---

# Tải tất cả file trong thư mục về local (giữ cấu trúc thư mục)
client.directories.download("models/qwen", "/tmp/qwen_model")

# --- Upload directory (SMART BATCHING) ---
#
# Logic:
#   - File <= 100MB: gom batch, chia sẻ xorb/shard → 1 API call cho tất cả
#   - File > 100MB:  upload riêng từng file
#   - Tự động pack chunks vào xorbs (max 64MB/xorb)
#   - 1 shard + 1 batch call cho toàn bộ small files

# Upload cả thư mục
client.directories.upload("./my_model_dir", "models/my_model")

# Upload với exclude patterns
client.directories.upload("./project", "backup/project",
  exclude: ["*.bin", "*.tmp", ".hidden", ".git/**", "__pycache__/**"]
)

# Exclude nhận string hoặc array
client.directories.upload("./src", "backup/src",
  exclude: "*.log"
)

# --- Move / Rename directory ---

client.directories.move("old_folder", "new_folder")
client.directories.rename("new_folder", "renamed_folder")

# --- Copy directory (trong cùng bucket) ---

# Copy 1 thư mục
client.directories.copy("models/qwen", "backup/qwen")

# Copy với kiểm soát overwrite (bỏ qua file đã tồn tại)
client.directories.copy("models/qwen", "backup/qwen", overwrite: false)

# Copy nhiều thư mục cùng lúc (array)
# Mỗi thư mục được copy vào destination prefix:
#   models/qwen   -> backup/models/qwen
#   models/llama  -> backup/models/llama
client.directories.copy(["models/qwen", "models/llama"], "backup/models")

# --- Copy directory từ repo bên ngoài (model/dataset/space/bucket) ---

# Copy thư mục từ model repo
client.directories.copy("tokenizer", "models/qwen/tokenizer",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy thư mục từ dataset repo
client.directories.copy("data/train", "datasets/train",
  source_type: "dataset",
  source_repo: "user/my-dataset",
  revision: "v1.0"
)

# Copy thư mục từ space
client.directories.copy("app", "spaces/my-app",
  source_type: "space",
  source_repo: "user/my-space"
)

# Copy thư mục từ bucket khác
client.directories.copy("backup/configs", "configs",
  source_type: "bucket",
  source_repo: "other-user/source-bucket"
)

# Copy nhiều thư mục từ model repo (array)
# Mỗi thư mục được copy vào destination prefix:
#   tokenizer_files -> models/qwen/tokenizer_files
#   configs         -> models/qwen/configs
client.directories.copy(["tokenizer_files", "configs"], "models/qwen",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy với exclude (bỏ qua file lớn)
client.directories.copy("weights", "models/qwen/weights",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# Copy toàn bộ repo root (string rỗng hoặc nil cho source_path)
client.directories.copy("", "models/gemma",
  source_type: "model",
  source_repo: "google/gemma-2-2b"
)

# --- Copy nhiều thư mục từ các nguồn khác nhau trong 1 batch ---
#
# Tất cả thư mục được liệt kê, phân loại và xử lý trong 1 batch.
# File xet: server-side copy; file git: download + upload.
# Mỗi thư mục có thể đến từ repo/loại nguồn khác nhau.

client.directories.copy_folders(
  folders: [
    { source_type: "model",  source_repo: "org/model-a",  source_path: "a/", destination: "new/" },
    { source_type: "model",  source_repo: "org/model-b",  source_path: "b/", destination: "new/" },
  ],
  overwrite: false,
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Đã tải #{path} (#{downloaded}/#{total})"
  }
)

# Nhiều loại nguồn: model + dataset + space trong 1 lần gọi
client.directories.copy_folders(
  folders: [
    { source_type: "model",   source_repo: "org/model-a",    source_path: "tokenizer/", destination: "models/a/tokenizer/" },
    { source_type: "dataset", source_repo: "org/data-b",     source_path: "data/",      destination: "data/backup/" },
    { source_type: "space",   source_repo: "org/space-c",    source_path: "app/",       destination: "spaces/c/" },
    { source_type: "bucket",  source_repo: "org/backup",     source_path: "configs/",   destination: "configs/" },
  ]
)

# Revision và exclude riêng cho từng thư mục
client.directories.copy_folders(
  folders: [
    { source_type: "model", source_repo: "org/model", source_path: "weights/", destination: "models/v2/", revision: "v2.0", exclude: ["*.bin"] },
    { source_type: "model", source_repo: "org/model", source_path: "configs/", destination: "models/v2/configs/" },
  ]
)

# --- Delete directory ---

# Xóa 1 thư mục rỗng
client.directories.delete("empty_folder")

# Xóa thư mục có file (recursive)
client.directories.delete("renamed_folder", recursive: true)

# Xóa nhiều thư mục cùng lúc
client.directories.delete(["old_folder", "temp_dir"], recursive: true)

# Copy toàn bộ tree
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/source-bucket",
  tree: "path/to/tree.json",           # file path hoặc Array
  destination_prefix: "backup/model"    # prefix đích
)

# Copy với source_prefix (chỉ copy files trong thư mục con)
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/ai-models",
  tree: "ai-models-tree.json",
  source_prefix: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen"
)

# Copy với exclude (bỏ qua file lớn)
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/ai-models",
  tree: "ai-models-tree.json",
  source_prefix: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen-configs",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# Copy từ model repo
client.directories.copy_from_tree(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  tree: tree_array,                    # Array of entries
  destination_prefix: "models/qwen"
)

# Tree cũng nhận Array trực tiếp (không cần file JSON)
tree_data = [
  { "type" => "file", "path" => "config.json", "size" => 660, "xetHash" => "3a1f..." },
  { "type" => "file", "path" => "tokenizer.json", "size" => 7031645, "xetHash" => "adad..." },
]
client.directories.copy_from_tree(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  tree: tree_data,
  destination_prefix: "models/qwen"
)

# ============================================================
# COPY TỪ REPO (Tự động list + copy model/dataset từ Hub)
# ============================================================
#
# Copy nguyên model/dataset trực tiếp từ HuggingFace Hub.
# Không cần file tree JSON, tự động:
#   - Xet files: server-side copy (zero data transfer)
#   - Small git files: download + re-upload qua xet
#   - LFS chưa migrate: raise error

# --- Copy toàn bộ model ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "moonshotai/MoonViT-SO-400M",
  destination_prefix: "models/moonvit"
)
# => { files_copied: 8, files_downloaded: 3, total_size: ..., source: "model:..." }

# --- Copy dataset ---

client.directories.copy_from_repo(
  source_type: "dataset",
  source_repo: "user/my-dataset",
  destination_prefix: "datasets/my-dataset"
)

# --- Copy từ bucket khác ---

client.directories.copy_from_repo(
  source_type: "bucket",
  source_repo: "other-user/source-bucket",
  destination_prefix: "backup/source"
)

# --- Copy thư mục con trong model ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "tokenizer_files",
  destination_prefix: "models/qwen/tokenizer"
)

# --- Copy với exclude (bỏ qua file lớn) ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen-configs",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# --- Copy revision cụ thể ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "user/my-model",
  revision: "v2.0",
  destination_prefix: "models/my-model-v2"
)

# ============================================================
# LOGGING - Thay đổi tại runtime
# ============================================================

# Xem log level hiện tại
puts client.log_level  # :info

# Bật debug (hiện chi tiết HTTP request/response headers/body)
client.log_level = :debug
client.files.list(prefix: "models")
# Output sẽ hiện:
#   GET https://huggingface.co/api/buckets/.../tree/models
#   Request Headers:
#     authorization: Bearer hf_...[REDACTED]
#     content-type: application/json
#   Response: HTTP 200
#   Response Headers:
#     content-type: application/json; charset=utf-8
#     ratelimit: "api";r=998;t=130
#   Response Body: [{"type":"file",...}]

# Tắt bớt log
client.log_level = :warn

# Đóng logger khi ghi ra file
# client.logger.close

# ============================================================
# ERROR HANDLING
# ============================================================

begin
  client.files.metadata("nonexistent/file.txt")
rescue HuggingFaceStorage::NotFoundError => e
  puts "File not found: #{e.message}"
rescue HuggingFaceStorage::AuthenticationError => e
  puts "Auth failed: #{e.message}"
rescue HuggingFaceStorage::ApiError => e
  puts "API error (HTTP #{e.status}): #{e.message}"
  puts "Response body: #{e.body}"
rescue HuggingFaceStorage::Error => e
  puts "General error: #{e.message}"
end

# ============================================================
# TIPS & BEST PRACTICES
# ============================================================

# 1. Upload thư mục nhiều file nhỏ → dùng directories.upload (auto batch)
#    20 files → 1 xorb + 1 shard + 1 batch call = 4 API calls

# 2. Copy model lớn giữa buckets → dùng copy_from_tree + exclude
#    Copy model 3GB server-side trong vài giây

# 3. Dùng log_level: :debug khi cần debug API calls
#    Chuyển về :info hoặc :warn khi chạy production

# 4. Dùng copy_file / copy_files thay vì copy_from nếu bạn chưa biết xetHash
#    Tự phân loại và xử lý xet/LFS/git files

# 5. copy_files chấp nhận files từ nhiều repo khác nhau trong 1 lần gọi
#    Model weights từ org/model-a + config từ org/model-b = 1 batch

# 6. Lấy xetHash từ list/metadata để dùng cho copy_from
#    hash = client.files.metadata("path")&.xet_hash

# 7. Exclude patterns dùng glob:
#    "*.bin"              - match basename
#    "models/*.bin"       - match relative path
#    ".git/**"            - match directory tree
#    ["*.tmp", "*.log"]   - multiple patterns
