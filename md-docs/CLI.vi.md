# hfs — Tài liệu CLI

> 🌐 Language / Ngôn ngữ: [English](CLI.md) | **Tiếng Việt**

## Tổng quan

`hfs` là giao diện dòng lệnh cho HuggingFace Storage Buckets. Nó được xây dựng trên [Thor](https://github.com/rails/thor) và hoàn toàn bằng Ruby — không phụ thuộc Python, không gọi CLI ngoài.

Điểm vào nhị phân là `bin/hfs`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../src/hugging_face_storage"

HuggingFaceStorage::CLI.start(ARGV)
```

---

## Xác thực

CLI cần token HuggingFace. Thứ tự ưu tiên:

1. Tùy chọn `--token` CLI
2. Biến môi trường `HF_TOKEN`
3. File `~/.huggingface/token` (token phiên HuggingFace Hub)

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

---

## Tùy chọn toàn cục

Có sẵn cho mọi lệnh:

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--token` | String | — | Token HuggingFace (ghi đè biến môi trường `HF_TOKEN`) |
| `--format` | String | `text` | Định dạng đầu ra: `text` hoặc `json` |
| `--json` | Boolean | — | Viết tắt cho `--format json` |
| `--log-level` | String | `warn` | Mức log: `debug`, `info`, `warn`, `error` |

---

## Định dạng Bucket

Tất cả lệnh đều chấp nhận bucket ở dạng `namespace/name`:

```
user/my-bucket
my-org/data-bucket
```

---

## Các lệnh

### `upload`

Tải lên một file, thư mục hoặc glob pattern vào bucket.

**Cách dùng:**

```
bin/hfs upload BUCKET LOCAL_PATH [REMOTE_PATH]
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket (`namespace/name`) |
| `LOCAL_PATH` | có | Đường dẫn file, thư mục hoặc glob pattern |
| `REMOTE_PATH` | không | Đường dẫn đích từ xa (mặc định là tên file của LOCAL_PATH) |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--exclude` | String (lặp lại được) | — | Glob pattern để loại trừ (`*.log`, `*.tmp`) |
| `--parallel` | Numeric | `4` | Số luồng tải lên cho thư mục |

**Hành vi:**

- Nếu `LOCAL_PATH` là thư mục → tải lên tất cả file bên trong với smart batching
- Nếu `LOCAL_PATH` chứa ký tự glob (`*`, `?`, `[`, `]`, `{`, `}`) → tải lên các file khớp
- Ngược lại → tải lên như một file đơn

**Ví dụ:**

```bash
# Tải lên một file
bin/hfs upload user/my-bucket ./model.bin models/model.bin

# Tải lên với tên tự động (remote path mặc định là tên file)
bin/hfs upload user/my-bucket ./config.json

# Tải lên thư mục (smart batching)
bin/hfs upload user/my-bucket ./my_model_dir models/my-model

# Tải lên với glob pattern
bin/hfs upload user/my-bucket "./data/*.csv" data/

# Loại trừ một số file
bin/hfs upload user/my-bucket ./project models/project \
  --exclude "*.log" --exclude "*.tmp"
```

---

### `download`

Tải xuống một file hoặc thư mục từ bucket.

**Cách dùng:**

```
bin/hfs download BUCKET REMOTE_PATH LOCAL_PATH
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket (`namespace/name`) |
| `REMOTE_PATH` | có | Đường dẫn file hoặc thư mục từ xa |
| `LOCAL_PATH` | có | Đường dẫn đích local |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--parallel` | Numeric | `4` | Số luồng tải xuống cho thư mục |

**Hành vi:**

- Đầu tiên kiểm tra nếu `REMOTE_PATH` là file → tải xuống file đơn
- Sau đó kiểm tra nếu là thư mục → tải xuống thư mục song song
- Ngược lại → lỗi "Not found"

**Ví dụ:**

```bash
# Tải xuống một file
bin/hfs download user/my-bucket models/config.json ./config.json

# Tải xuống thư mục (song song)
bin/hfs download user/my-bucket models/qwen ./qwen \
  --parallel 8
```

---

### `copy`

Sao chép file hoặc thư mục trong cùng bucket hoặc từ repo HuggingFace bên ngoài (phía máy chủ, không truyền dữ liệu local).

**Cách dùng:**

```
bin/hfs copy BUCKET SOURCE DEST
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket đích |
| `SOURCE` | có | Đường dẫn nguồn |
| `DEST` | có | Đường dẫn đích |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--from_repo` | String | — | Repo nguồn dạng `type:name` (ví dụ `model:Qwen/Qwen2.5-0.5B-Instruct`) |
| `--source_type` | String | `bucket` | Loại nguồn (dùng với `--from_repo`) |

**Loại nguồn cho `--from_repo`:**

| Loại | Tiền tố | Ví dụ |
|------|---------|-------|
| `model` | `model:` | `model:Qwen/Qwen2.5-0.5B-Instruct` |
| `dataset` | `dataset:` | `dataset:org/my-data` |
| `space` | `space:` | `space:org/my-space` |

**Ví dụ:**

```bash
# Copy trong cùng bucket
bin/hfs copy user/my-bucket models/v1/config.json models/v2/config.json

# Copy từ HuggingFace model (phía máy chủ, không truyền dữ liệu)
bin/hfs copy user/my-bucket tokenizer models/qwen/tokenizer \
  --from_repo "model:Qwen/Qwen2.5-0.5B-Instruct"

# Copy từ dataset repo
bin/hfs copy user/my-bucket data/ data/backup \
  --from_repo "dataset:org/my-data"
```

---

### `delete`

Xóa một file hoặc thư mục khỏi bucket.

**Cách dùng:**

```
bin/hfs delete BUCKET PATH
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `PATH` | có | Đường dẫn cần xóa |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--recursive` / `-r` | Boolean | `true` | Xóa thư mục đệ quy |
| `--force` / `-f` | Boolean | `false` | Bỏ qua xác nhận |

**Hành vi:**

- Yêu cầu xác nhận trừ khi dùng `--force`
- Kiểm tra nếu `PATH` là file trước, sau đó là thư mục
- Mặc định xóa thư mục đệ quy

**Ví dụ:**

```bash
# Xóa với xác nhận
bin/hfs delete user/my-bucket old-model.pt

# Xóa không cần xác nhận
bin/hfs delete user/my-bucket temp-dir --force

# Xóa thư mục không đệ quy
bin/hfs delete user/my-bucket some-dir --no-recursive --force
```

---

### `move`

Di chuyển hoặc đổi tên file hoặc thư mục trong bucket.

**Cách dùng:**

```
bin/hfs move BUCKET SOURCE DEST
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `SOURCE` | có | Đường dẫn nguồn |
| `DEST` | có | Đường dẫn đích |

**Ví dụ:**

```bash
# Di chuyển/đổi tên file
bin/hfs move user/my-bucket old-name.bin new-name.bin

# Di chuyển thư mục
bin/hfs move user/my-bucket staging/model production/model
```

---

### `list`

Liệt kê các file trong bucket, tùy chọn lọc theo tiền tố.

**Cách dùng:**

```
bin/hfs list BUCKET [PATH]
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `PATH` | không | Tiền tố đường dẫn tùy chọn để lọc |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--recursive` / `-r` | Boolean | `false` | Liệt kê file đệ quy |
| `--format` | String | `table` | Định dạng đầu ra: `table` hoặc `json` |

**Ví dụ:**

```bash
# Liệt kê tất cả file (không đệ quy)
bin/hfs list user/my-bucket

# Liệt kê file trong thư mục đệ quy
bin/hfs list user/my-bucket models/ -r

# Đầu ra JSON
bin/hfs list user/my-bucket --format json

# Liệt kê file theo tiền tố
bin/hfs list user/my-bucket models/qwen
```

**Cột bảng:** `path`, `size`, `xet_hash` (12 ký tự đầu), `mtime`

---

### `info`

Hiển thị metadata cho bucket, file hoặc thư mục.

**Cách dùng:**

```
bin/hfs info BUCKET [PATH]
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `PATH` | không | Đường dẫn file hoặc thư mục tùy chọn |

**Hành vi:**

- Không có PATH → hiển thị thông tin bucket (tên, kích thước, v.v.)
- PATH là file → hiển thị metadata file (đường dẫn, kích thước, xet_hash, mtime)
- PATH là thư mục → hiển thị metadata thư mục (đường dẫn, số file, tổng kích thước)

Đầu ra luôn là JSON.

**Ví dụ:**

```bash
# Thông tin bucket
bin/hfs info user/my-bucket

# Metadata file
bin/hfs info user/my-bucket models/config.json

# Metadata thư mục
bin/hfs info user/my-bucket models/qwen
```

---

### `snapshot`

Tải xuống snapshot thư mục với JSON manifest để xác minh.

**Cách dùng:**

```
bin/hfs snapshot BUCKET REMOTE_PATH LOCAL_DIR
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `REMOTE_PATH` | có | Đường dẫn thư mục từ xa |
| `LOCAL_DIR` | có | Thư mục đích local |

**Tùy chọn:**

| Tùy chọn | Kiểu | Mặc định | Mô tả |
|----------|------|----------|-------|
| `--verify` | Boolean | `false` | Xác minh file đã tải xuống với manifest |

**Ví dụ:**

```bash
# Tải snapshot không xác minh
bin/hfs snapshot user/my-bucket models/qwen ./qwen-snapshot

# Tải snapshot với xác minh toàn vẹn
bin/hfs snapshot user/my-bucket models/qwen ./qwen-snapshot --verify
```

---

### `edit`

Chỉnh sửa file từ xa tại chỗ không cần chu kỳ download/upload.

**Cách dùng:**

```
bin/hfs edit BUCKET REMOTE_PATH --edits JSON
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket |
| `REMOTE_PATH` | có | Đường dẫn file từ xa |

**Tùy chọn:**

| Tùy chọn | Kiểu | Bắt buộc | Mô tả |
|----------|------|----------|-------|
| `--edits` | String | có | Mảng JSON các thao tác chỉnh sửa |

**Định dạng thao tác chỉnh sửa:**

Mỗi thao tác chỉnh sửa hỗ trợ hai loại:

| Loại | Trường | Mô tả |
|------|--------|-------|
| `replace` | `old`, `new` | Tìm/thay thế bằng khớp chuỗi chính xác |
| `patch` | `offset`, `content` | Thay thế byte tại offset nhất định (cấp API, không phải CLI) |

**Ví dụ:**

```bash
# Thay thế chuỗi trong file từ xa
bin/hfs edit user/my-bucket config.json \
  --edits '[{"type":"replace","old":"\"version\": 1","new":"\"version\": 2"}]'

# Nhiều thao tác chỉnh sửa
bin/hfs edit user/my-bucket settings.json \
  --edits '[
    {"type":"replace","old":"debug: true","new":"debug: false"},
    {"type":"replace","old":"log_level: info","new":"log_level: warn"}
  ]'
```

---

### `buckets list`

Liệt kê các bucket trong một namespace.

**Cách dùng:**

```
bin/hfs buckets list [NAMESPACE]
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `NAMESPACE` | không | Namespace (dự phòng xuống biến môi trường `HF_NAMESPACE`) |

**Ví dụ:**

```bash
# Liệt kê bucket cho namespace
bin/hfs buckets list my-org

# Liệt kê bucket dùng biến môi trường
export HF_NAMESPACE=my-org
bin/hfs buckets list
```

---

### `buckets info`

Hiển thị thông tin chi tiết về một bucket cụ thể.

**Cách dùng:**

```
bin/hfs buckets info BUCKET
```

**Tham số:**

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `BUCKET` | có | Định danh bucket (`namespace/name`) |

**Ví dụ:**

```bash
bin/hfs buckets info user/my-bucket
```

---

## Hệ thống trợ giúp

Mọi lệnh đều hỗ trợ `--help` (hoặc `help` như một lệnh con):

```bash
# Liệt kê tất cả lệnh
bin/hfs help

# Trợ giúp lệnh cụ thể
bin/hfs help upload
bin/hfs help delete
bin/hfs help buckets

# Cách viết tắt
bin/hfs upload --help
bin/hfs delete --help
```

---

## Định dạng đầu ra

Mặc định, các lệnh xuất ra văn bản dễ đọc cho con người. Dùng `--json` hoặc `--format json` cho đầu ra máy đọc được:

```bash
# Dễ đọc cho người
bin/hfs list user/my-bucket

# Đầu ra JSON cho máy
bin/hfs list user/my-bucket --json
bin/hfs list user/my-bucket --format json
```

Một số lệnh (`info`, `buckets info`) luôn xuất ra JSON.

Tùy chọn toàn cục `--format` (`text` / `json`) có sẵn trên mọi lệnh. Lệnh `list` có thêm tùy chọn `--format table` cho đầu ra dạng bảng.

---

## Hướng dẫn mã nguồn

Mã nguồn CLI nằm dưới `src/hugging_face_storage/cli/`.

### Bản đồ file

| File | Mục đích |
|------|----------|
| `bin/hfs` | Điểm vào — `require` thư viện và gọi `CLI.start(ARGV)` |
| `cli/cli.rb` | Lớp `CLI < Thor` chính — định nghĩa lệnh, tùy chọn toàn cục, dispatch |
| `cli/buckets_cli.rb` | `BucketsCLI < Thor` — lệnh con cho `buckets list` / `buckets info` |
| `cli/formatter.rb` | Module `CLIFormatter` — định dạng bảng/JSON, xây dựng client |
| `cli/commands/transfer.rb` | Module `Transfer` — triển khai `upload`, `download` |
| `cli/commands/manage.rb` | Module `Manage` — triển khai `delete`, `move`, `list`, `info` |
| `cli/commands/copy_commands.rb` | Module `CopyCommands` — triển khai `copy` |
| `cli/commands/advanced.rb` | Module `Advanced` — triển khai `snapshot`, `edit` |
| `spec/.../cli/cli_spec.rb` | Spec CLI — 568 dòng bao phủ mọi lệnh, tùy chọn, lỗi |
| `spec/.../cli/buckets_cli_spec.rb` | Spec BucketsCLI |
| `spec/.../cli/commands/copy_commands_spec.rb` | Spec lệnh copy |
| `spec/.../cli/formatter_spec.rb` | Spec Formatter — định dạng bảng/JSON, xây dựng client |
| `spec/.../cli/commands/manage_spec.rb` | Spec lệnh Manage — delete, move, list, info |
| `spec/.../cli/commands/transfer_spec.rb` | Spec lệnh Transfer — upload, download |
| `spec/.../cli/commands/advanced_spec.rb` | Spec lệnh Advanced — snapshot, edit |

### Kiến trúc

```
CLI < Thor
├── upload, download          ← Module Transfer
├── delete, move, list, info  ← Module Manage
├── copy                      ← Module CopyCommands
├── snapshot, edit            ← Module Advanced
└── buckets (lệnh con)        ← BucketsCLI
```

### Cách dispatch hoạt động

Mỗi phương thức CLI (ví dụ `def upload`) gọi phương thức `dispatch` private, sử dụng `UnboundMethod#bind_call` của Ruby để gọi triển khai từ module đúng. Điều này tránh sự mơ hồ về thứ tự giải quyết phương thức khi include nhiều module:

```ruby
def dispatch(method_name, mod, *args)
  mod.instance_method(method_name).bind_call(self, *args)
end
```

### Cách client được xây dựng

`CLIFormatter.build_client` xử lý phân giải xác thực:

1. Phân tích `BUCKET` thành `namespace` và `name`
2. Dùng tùy chọn `--token`, sau đó biến môi trường `HF_TOKEN`, sau đó file `~/.huggingface/token`
3. Xây dựng `HuggingFaceStorage::Client` với `log_level` từ tùy chọn `--log-level` (mặc định: `:warn`)

### Cách định dạng đầu ra hoạt động

Helper `format_or_say` kiểm tra `--json` / `--format`:

```ruby
def format_or_say(result)
  if options[:json] || options[:format] == "json"
    say CLIFormatter.format_json(result)
  else
    yield  # thông báo dễ đọc cho người
  end
end
```

`CLIFormatter` cung cấp:
- `format_table(rows, headers)` — đầu ra bảng tự động độ rộng
- `format_json(data)` — `JSON.pretty_generate`
- `format_error(message, hint:)` — lỗi tô màu ANSI với gợi ý màu vàng
- `format_output(data, format, headers:)` — điều phối đến bảng hoặc JSON

### Mở rộng CLI

Để thêm lệnh mới:

1. Định nghĩa phương thức triển khai trong module mới hoặc có sẵn dưới `cli/commands/`
2. Khai báo lệnh Thor trong `cli.rb` với `desc`, `option`, `def`
3. Gọi `dispatch(:method_name, ModuleName, *args)` bên trong phương thức
4. Thêm spec trong `spec/hugging_face_storage/cli/`
