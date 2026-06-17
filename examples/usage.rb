# frozen_string_literal: true

# ============================================================
# HuggingFace Storage - Ruby Client Usage Examples
# ============================================================
#
# Requirements:
#   - gem install digest-blake3
#   - export HF_TOKEN=hf_xxx
#
# Run:
#   ruby examples/usage.rb

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "hugging_face_storage"

# ============================================================
# CLIENT INITIALIZATION
# ============================================================

# Basic
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket"
)

# With full logging
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

# Log to file
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :debug,
  log_output: "/tmp/hf_storage.log",
  log_format: :default
)

# JSON log format (suitable for log aggregation)
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :info,
  log_format: :json
)
# Output: {"timestamp":"2026-06-05T21:30:00.000+07:00","level":"INFO","message":"..."}

# Short log format
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :info,
  log_format: :short
)
# Output: I 21:30:00 Uploading file: ...

# Custom log format (Proc)
client = HuggingFaceStorage.new(
  token: ENV["HF_TOKEN"],
  namespace: "your-username",
  bucket: "your-bucket",
  log_level: :debug,
  log_format: ->(time, level, msg, color) { ">> [#{level}] #{msg}" }
)

# Debug mode (preserves backtraces in errors)
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

# Get current bucket info
info = client.bucket_info
puts "Bucket: #{info["id"]}, files=#{info["totalFiles"]}, size=#{info["size"]}"

# List all user buckets
buckets = client.list_buckets
buckets.each { |b| puts "  #{b["id"]} (#{b["totalFiles"]} files)" }

# ============================================================
# FILE OPERATIONS
# ============================================================

# --- Upload ---

# Upload file from local
result = client.files.upload("./local_model.bin", "models/model.bin")
puts "Uploaded: #{result.inspect}"

# Upload raw bytes (string)
client.files.upload_bytes("hello world", "notes/readme.txt")

# Upload binary data
binary_data = File.binread("./image.png")
client.files.upload_bytes(binary_data, "images/logo.png")

# --- List ---

# List files at root (non-recursive)
root_files = client.files.list
root_files.each { |f| puts "  #{f.name} (#{f.size} bytes)" }

# List files recursive (all files in bucket)
all_files = client.files.list(recursive: true)
puts "Total files: #{all_files.size}"

# List files in a specific directory
model_files = client.files.list(prefix: "models/qwen")
model_files.each { |f| puts "  #{f.path} (#{f.size} bytes)" }

# List recursive in directory
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

# --- Copy (within same bucket) ---

client.files.copy("models/qwen/config.json", "backup/qwen_config.json")

# --- Move / Rename ---

# Move file
client.files.move("notes/readme.txt", "archive/readme.txt")

# Rename (essentially a move)
client.files.rename("archive/readme.txt", "archive/readme_v2.txt")

# --- Delete ---

# Delete single file
client.files.delete("archive/readme_v2.txt")

# Delete multiple files at once
client.files.delete(["old/file1.txt", "old/file2.bin", "old/file3.json"])

# Directory detection — raises Error with hint to use directories.delete:
#   client.files.delete("models/assets")
#   => Error: 'models/assets' is a directory. Use client.directories.delete instead.
#   client.files.delete(["a.txt", "models/assets", "b.txt"])
#   => Error: 'models/assets' is a directory. Use client.directories.delete instead.

# ============================================================
# CROSS-REPO COPY (Server-side, NO download/upload data)
# ============================================================
#
# Copy files between buckets/models/datasets using xetHash.
# Data does not pass through the local machine - purely server-side.
# Copying a 3GB file takes just 1 API call.

# --- Copy single file by xetHash ---

client.files.copy_from(
  source_type: "bucket",                          # "bucket" | "model" | "dataset"
  source_repo: "other-user/other-bucket",         # source repo ID
  source_path: "models/config.json",               # source path (for logging)
  xet_hash: "3a1f858c414da4362c5df3e40b110ff313fd2a85b7ee3464a1d48e4ebf5b2114",
  destination: "copied/config.json"                # destination path
)

# Copy from model repo
client.files.copy_from(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  xet_hash: "<xet_hash_of_config>",
  destination: "models/qwen/config.json"
)

# --- Batch copy multiple files ---

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
# COPY FILE / FILES (Auto classify + handle non-xet files)
# ============================================================
#
# Higher-level copy APIs that automatically classify source files:
#   - xet-backed => server-side copy (zero data transfer)
#   - LFS (unmigrated) => raises Error with file list + sizes
#   - Regular git file => downloads + re-uploads via xet
#
# Unlike copy_from (which requires xetHash), copy_file / copy_files
# look up the file metadata for you and handle all three cases.

# --- Copy single file from model/dataset/bucket ---

# xet-backed: server-side copy, no download
client.files.copy_file(
  source_type: "model",
  source_repo: "google/gemma-2-2b",
  source_path: "model.safetensors",
  destination: "models/gemma-2/model.safetensors"
)

# From dataset with specific revision
client.files.copy_file(
  source_type: "dataset",
  source_repo: "user/my-dataset",
  source_path: "data/train.csv",
  destination: "datasets/train.csv",
  revision: "v1.0"
)

# Small git file (e.g. config.json): auto download + re-upload
client.files.copy_file(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "config.json",
  destination: "models/qwen/config.json"
)

# Destination ending with "/" auto-appends the filename:
# "models/gemma-2/" + "model.safetensors" = "models/gemma-2/model.safetensors"
client.files.copy_file(
  source_type: "model",
  source_repo: "google/gemma-2-2b",
  source_path: "model.safetensors",
  destination: "models/gemma-2/"
)

# From another bucket (revision is ignored)
client.files.copy_file(
  source_type: "bucket",
  source_repo: "other-user/source-bucket",
  source_path: "backup/data.bin",
  destination: "imported/data.bin"
)

# With progress tracking for single file
client.files.copy_file(
  source_type: "model",
  source_repo: "org/model",
  source_path: "large_weights.bin",
  destination: "models/weights.bin",
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Downloaded #{path} (#{downloaded}/#{total})"
  }
)

# With overwrite control (skip if destination exists)
client.files.copy_file(
  source_type: "model",
  source_repo: "org/model",
  source_path: "config.json",
  destination: "models/config.json",
  overwrite: false  # skip if already exists
)

# --- Copy multiple files from different repos in one batch ---
#
# All files are classified and processed in a single batch commit.
# xet files: server-side copy; git files: downloaded + uploaded.

client.files.copy_files(
  files: [
    # From model repo (xet file → server-side copy)
    { source_type: "model",  source_repo: "org/model-a",  source_path: "weights.bin", destination: "models/weights.bin" },
    # From dataset (small git file → download + upload)
    { source_type: "dataset", source_repo: "org/data-b",  source_path: "labels.csv",  destination: "data/labels.csv"   },
    # From another bucket (xet file → server-side)
    { source_type: "bucket",  source_repo: "org/backup",   source_path: "archive.bin", destination: "backup/archive.bin" },
  ]
)

# With progress tracking
client.files.copy_files(
  files: [
    { source_type: "model", source_repo: "org/model-a", source_path: "a.bin", destination: "a.bin" },
    { source_type: "model", source_repo: "org/model-a", source_path: "b.bin", destination: "b.bin" },
  ],
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Downloaded #{path} (#{downloaded}/#{total})"
  }
)

# --- Copy from tree JSON (most convenient) ---
#
# Read a tree JSON file (from list_bucket_tree / list_repo_tree)
# and batch-copy files server-side.
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

# Directories at root
dirs = client.directories.list
dirs.each { |d| puts "  #{d.path}" }

# Subdirectories
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

# Download all files in a directory to local (preserve directory structure)
client.directories.download("models/qwen", "/tmp/qwen_model")

# --- Upload directory (SMART BATCHING) ---
#
# Logic:
#   - File <= 100MB: batch together, share xorb/shard → 1 API call for all
#   - File > 100MB:  upload each file individually
#   - Automatically pack chunks into xorbs (max 64MB/xorb)
#   - 1 shard + 1 batch call for all small files

# Upload entire directory
client.directories.upload("./my_model_dir", "models/my_model")

# Upload with exclude patterns
client.directories.upload("./project", "backup/project",
  exclude: ["*.bin", "*.tmp", ".hidden", ".git/**", "__pycache__/**"]
)

# Exclude accepts string or array
client.directories.upload("./src", "backup/src",
  exclude: "*.log"
)

# --- Move / Rename directory ---

client.directories.move("old_folder", "new_folder")
client.directories.rename("new_folder", "renamed_folder")

# --- Copy directory (within same bucket) ---

# Copy single directory
client.directories.copy("models/qwen", "backup/qwen")

# Copy with overwrite control (skip existing files)
client.directories.copy("models/qwen", "backup/qwen", overwrite: false)

# Copy multiple directories at once (array)
# Each directory is copied into the destination prefix:
#   models/qwen   -> backup/models/qwen
#   models/llama  -> backup/models/llama
client.directories.copy(["models/qwen", "models/llama"], "backup/models")

# --- Copy directory from external repos (model/dataset/space/bucket) ---

# Copy directory from model repo
client.directories.copy("tokenizer", "models/qwen/tokenizer",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy directory from dataset repo
client.directories.copy("data/train", "datasets/train",
  source_type: "dataset",
  source_repo: "user/my-dataset",
  revision: "v1.0"
)

# Copy directory from space
client.directories.copy("app", "spaces/my-app",
  source_type: "space",
  source_repo: "user/my-space"
)

# Copy directory from another bucket
client.directories.copy("backup/configs", "configs",
  source_type: "bucket",
  source_repo: "other-user/source-bucket"
)

# Copy multiple directories from model repo (array)
# Each directory is copied into the destination prefix:
#   tokenizer_files -> models/qwen/tokenizer_files
#   configs         -> models/qwen/configs
client.directories.copy(["tokenizer_files", "configs"], "models/qwen",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct"
)

# Copy with exclude (skip large files)
client.directories.copy("weights", "models/qwen/weights",
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# Copy entire repo root (empty string or nil for source_path)
client.directories.copy("", "models/gemma",
  source_type: "model",
  source_repo: "google/gemma-2-2b"
)

# --- Copy multiple folders from different sources in one batch ---
#
# All folders are listed, classified, and processed in a single batch.
# xet files: server-side copy; git files: downloaded + uploaded.
# Each folder can come from a different repo/source type.

client.directories.copy_folders(
  folders: [
    { source_type: "model",  source_repo: "org/model-a",  source_path: "a/", destination: "new/" },
    { source_type: "model",  source_repo: "org/model-b",  source_path: "b/", destination: "new/" },
  ],
  overwrite: false,
  on_progress: ->(path:, downloaded:, total:) {
    puts "  Downloaded #{path} (#{downloaded}/#{total})"
  }
)

# Mixed source types: model + dataset + space in one call
client.directories.copy_folders(
  folders: [
    { source_type: "model",   source_repo: "org/model-a",    source_path: "tokenizer/", destination: "models/a/tokenizer/" },
    { source_type: "dataset", source_repo: "org/data-b",     source_path: "data/",      destination: "data/backup/" },
    { source_type: "space",   source_repo: "org/space-c",    source_path: "app/",       destination: "spaces/c/" },
    { source_type: "bucket",  source_repo: "org/backup",     source_path: "configs/",   destination: "configs/" },
  ]
)

# Per-folder revision and exclude
client.directories.copy_folders(
  folders: [
    { source_type: "model", source_repo: "org/model", source_path: "weights/", destination: "models/v2/", revision: "v2.0", exclude: ["*.bin"] },
    { source_type: "model", source_repo: "org/model", source_path: "configs/", destination: "models/v2/configs/" },
  ]
)

# --- Delete directory ---

# Delete empty directory
client.directories.delete("empty_folder")

# Delete directory with files (recursive)
client.directories.delete("renamed_folder", recursive: true)

# Delete multiple directories at once
client.directories.delete(["old_folder", "temp_dir"], recursive: true)

# Copy entire tree
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/source-bucket",
  tree: "path/to/tree.json",           # file path or Array
  destination_prefix: "backup/model"    # destination prefix
)

# Copy with source_prefix (only copy files in a subdirectory)
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/ai-models",
  tree: "ai-models-tree.json",
  source_prefix: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen"
)

# Copy with exclude (skip large files)
client.directories.copy_from_tree(
  source_type: "bucket",
  source_repo: "user/ai-models",
  tree: "ai-models-tree.json",
  source_prefix: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen-configs",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# Copy from model repo
client.directories.copy_from_tree(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  tree: tree_array,                    # Array of entries
  destination_prefix: "models/qwen"
)

# Tree also accepts Array directly (no JSON file needed)
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
# COPY FROM REPO (Auto list + copy model/dataset from Hub)
# ============================================================
#
# Copy entire model/dataset directly from HuggingFace Hub.
# No tree JSON file needed. Automatically:
#   - Xet files: server-side copy (zero data transfer)
#   - Small git files: download + re-upload via xet
#   - LFS not yet migrated: raise error

# --- Copy entire model ---

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

# --- Copy from another bucket ---

client.directories.copy_from_repo(
  source_type: "bucket",
  source_repo: "other-user/source-bucket",
  destination_prefix: "backup/source"
)

# --- Copy subdirectory within a model ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  source_path: "tokenizer_files",
  destination_prefix: "models/qwen/tokenizer"
)

# --- Copy with exclude (skip large files) ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "Qwen/Qwen2.5-0.5B-Instruct",
  destination_prefix: "models/qwen-configs",
  exclude: ["*.safetensors", "*.bin", "*.pt"]
)

# --- Copy specific revision ---

client.directories.copy_from_repo(
  source_type: "model",
  source_repo: "user/my-model",
  revision: "v2.0",
  destination_prefix: "models/my-model-v2"
)

# ============================================================
# LOGGING - Change at runtime
# ============================================================

# View current log level
puts client.log_level  # :info

# Enable debug (shows HTTP request/response headers/body in detail)
client.log_level = :debug
client.files.list(prefix: "models")
# Output will show:
#   GET https://huggingface.co/api/buckets/.../tree/models
#   Request Headers:
#     authorization: Bearer hf_...[REDACTED]
#     content-type: application/json
#   Response: HTTP 200
#   Response Headers:
#     content-type: application/json; charset=utf-8
#     ratelimit: "api";r=998;t=130
#   Response Body: [{"type":"file",...}]

# Reduce logging
client.log_level = :warn

# Close logger when writing to file
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

# 1. Upload directory with many small files → use directories.upload (auto batch)
#    20 files → 1 xorb + 1 shard + 1 batch call = 4 API calls

# 2. Copy large model between buckets → use copy_from_tree + exclude
#    Copy 3GB model server-side in seconds

# 3. Use log_level: :debug when debugging API calls
#    Switch to :info or :warn in production

# 4. Use copy_file / copy_files instead of copy_from when you don't know xetHash
#    They auto-classify and handle xet/LFS/git files automatically

# 5. copy_files accepts files from different repos in one call
#    Model weights from org/model-a + config from org/model-b = 1 batch

# 6. Get xetHash from list/metadata to use with copy_from
#    hash = client.files.metadata("path")&.xet_hash

# 7. Exclude patterns use glob:
#    "*.bin"              - match basename
#    "models/*.bin"       - match relative path
#    ".git/**"            - match directory tree
#    ["*.tmp", "*.log"]   - multiple patterns
