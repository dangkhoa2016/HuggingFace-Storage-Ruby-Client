# hfs — CLI Reference

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CLI.vi.md)

## Overview

`hfs` is the command-line interface for HuggingFace Storage Buckets. It is built on [Thor](https://github.com/rails/thor) and lives entirely in Ruby — no Python dependency, no external CLI calls.

The binary entry point is `bin/hfs`:

```ruby
#!/usr/bin/env ruby
require_relative "../src/hugging_face_storage"
require_relative "../src/hugging_face_storage/cli"
HuggingFaceStorage::CLI.start(ARGV)
```

---

## Authentication

The CLI needs a HuggingFace token. Priority order:

1. `--token` CLI option
2. `HF_TOKEN` environment variable
3. `~/.huggingface/token` file (HuggingFace Hub session token)

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

---

## Global Options

Available for every command:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--token` | String | — | HuggingFace token (overrides `HF_TOKEN` env) |
| `--format` | String | `text` | Output format: `text` or `json` |
| `--json` | Boolean | — | Shorthand for `--format json` |

---

## Bucket Specification

All commands accept a bucket in the form `namespace/name`:

```
user/my-bucket
my-org/data-bucket
```

---

## Commands

### `upload`

Upload a file, directory, or glob pattern to a bucket.

**Usage:**

```
hfs upload BUCKET LOCAL_PATH [REMOTE_PATH]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier (`namespace/name`) |
| `LOCAL_PATH` | yes | Local file, directory path, or glob pattern |
| `REMOTE_PATH` | no | Remote destination path (defaults to basename of LOCAL_PATH) |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--exclude` | String (repeatable) | — | Glob patterns to exclude (`*.log`, `*.tmp`) |
| `--parallel` | Numeric | `4` | Upload concurrency for directories |

**Behaviour:**

- If `LOCAL_PATH` is a directory → uploads all files inside with smart batching
- If `LOCAL_PATH` contains glob characters (`*`, `?`, `[`, `]`, `{`, `}`) → uploads matching files
- Otherwise → uploads as a single file

**Examples:**

```bash
# Upload a single file
hfs upload user/my-bucket ./model.bin models/model.bin

# Upload with auto-naming (remote path defaults to basename)
hfs upload user/my-bucket ./config.json

# Upload a directory (smart batching)
hfs upload user/my-bucket ./my_model_dir models/my-model

# Upload with glob pattern
hfs upload user/my-bucket "./data/*.csv" data/

# Exclude certain files
hfs upload user/my-bucket ./project models/project \
  --exclude "*.log" --exclude "*.tmp"
```

---

### `download`

Download a file or directory from a bucket.

**Usage:**

```
hfs download BUCKET REMOTE_PATH LOCAL_PATH
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier (`namespace/name`) |
| `REMOTE_PATH` | yes | Remote file or directory path |
| `LOCAL_PATH` | yes | Local destination path |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--parallel` | Numeric | `4` | Download concurrency for directories |

**Behaviour:**

- First checks if `REMOTE_PATH` is a file → downloads single file
- Then checks if it is a directory → parallel directory download
- Otherwise → error "Not found"

**Examples:**

```bash
# Download a file
hfs download user/my-bucket models/config.json ./config.json

# Download a directory (parallel)
hfs download user/my-bucket models/qwen ./qwen \
  --parallel 8
```

---

### `copy`

Copy a file or directory within the same bucket or from an external HuggingFace repo (server-side, no local data transfer).

**Usage:**

```
hfs copy BUCKET SOURCE DEST
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Destination bucket identifier |
| `SOURCE` | yes | Source path |
| `DEST` | yes | Destination path |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--from_repo` | String | — | Source repo in `type:name` format (e.g. `model:Qwen/Qwen2.5-0.5B-Instruct`) |
| `--source_type` | String | `bucket` | Source type (used with `--from_repo`) |

**Source types for `--from_repo`:**

| Type | Prefix | Example |
|------|--------|---------|
| `model` | `model:` | `model:Qwen/Qwen2.5-0.5B-Instruct` |
| `dataset` | `dataset:` | `dataset:org/my-data` |
| `space` | `space:` | `space:org/my-space` |

**Examples:**

```bash
# Copy within the same bucket
hfs copy user/my-bucket models/v1/config.json models/v2/config.json

# Copy from a HuggingFace model (server-side, no data transfer)
hfs copy user/my-bucket tokenizer models/qwen/tokenizer \
  --from_repo "model:Qwen/Qwen2.5-0.5B-Instruct"

# Copy from a dataset repo
hfs copy user/my-bucket data/ data/backup \
  --from_repo "dataset:org/my-data"
```

---

### `delete`

Delete a file or directory from a bucket.

**Usage:**

```
hfs delete BUCKET PATH
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `PATH` | yes | Path to delete |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--recursive` / `-r` | Boolean | `true` | Recursively delete directories |
| `--force` / `-f` | Boolean | `false` | Skip confirmation prompt |

**Behaviour:**

- Prompts for confirmation unless `--force` is given
- Checks if `PATH` is a file first, then directory
- By default deletes directories recursively

**Examples:**

```bash
# Delete with confirmation prompt
hfs delete user/my-bucket old-model.pt

# Delete without confirmation
hfs delete user/my-bucket temp-dir --force

# Delete a directory non-recursively
hfs delete user/my-bucket some-dir --no-recursive --force
```

---

### `move`

Move or rename a file or directory within a bucket.

**Usage:**

```
hfs move BUCKET SOURCE DEST
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `SOURCE` | yes | Source path |
| `DEST` | yes | Destination path |

**Examples:**

```bash
# Move/rename a file
hfs move user/my-bucket old-name.bin new-name.bin

# Move a directory
hfs move user/my-bucket staging/model production/model
```

---

### `list`

List files in a bucket, optionally filtered by prefix.

**Usage:**

```
hfs list BUCKET [PATH]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `PATH` | no | Optional path prefix to filter by |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--recursive` / `-r` | Boolean | `false` | List files recursively |
| `--format` | String | `table` | Output format: `table` or `json` |

**Examples:**

```bash
# List all files (non-recursive)
hfs list user/my-bucket

# List files in a directory recursively
hfs list user/my-bucket models/ -r

# JSON output
hfs list user/my-bucket --format json

# List files under a prefix
hfs list user/my-bucket models/qwen
```

**Table columns:** `path`, `size`, `xet_hash` (first 12 chars), `mtime`

---

### `info`

Show metadata for a bucket, file, or directory.

**Usage:**

```
hfs info BUCKET [PATH]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `PATH` | no | Optional file or directory path |

**Behaviour:**

- No PATH → shows bucket-level info (name, size, etc.)
- PATH is a file → shows file metadata (path, size, xet_hash, mtime)
- PATH is a directory → shows directory metadata (path, file_count, total_size)

Output is always JSON.

**Examples:**

```bash
# Bucket info
hfs info user/my-bucket

# File metadata
hfs info user/my-bucket models/config.json

# Directory metadata
hfs info user/my-bucket models/qwen
```

---

### `snapshot`

Download a directory snapshot with a JSON verification manifest.

**Usage:**

```
hfs snapshot BUCKET REMOTE_PATH LOCAL_DIR
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `REMOTE_PATH` | yes | Remote directory path |
| `LOCAL_DIR` | yes | Local destination directory |

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--verify` | Boolean | `false` | Verify downloaded files against the manifest |

**Examples:**

```bash
# Download snapshot without verification
hfs snapshot user/my-bucket models/qwen ./qwen-snapshot

# Download snapshot with integrity verification
hfs snapshot user/my-bucket models/qwen ./qwen-snapshot --verify
```

---

### `edit`

Edit a remote file in-place without a download/upload cycle.

**Usage:**

```
hfs edit BUCKET REMOTE_PATH --edits JSON
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier |
| `REMOTE_PATH` | yes | Remote file path |

**Options:**

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `--edits` | String | yes | JSON array of edit operations |

**Edit operation format:**

Each edit operation supports two types:

| Type | Fields | Description |
|------|--------|-------------|
| `replace` | `old`, `new` | Find/replace by exact string match |
| `patch` | `offset`, `content` | Replace bytes at given offset (API-level, not CLI) |

**Examples:**

```bash
# Replace a string in a remote file
hfs edit user/my-bucket config.json \
  --edits '[{"type":"replace","old":"\"version\": 1","new":"\"version\": 2"}]'

# Multiple edits
hfs edit user/my-bucket settings.json \
  --edits '[
    {"type":"replace","old":"debug: true","new":"debug: false"},
    {"type":"replace","old":"log_level: info","new":"log_level: warn"}
  ]'
```

---

### `buckets list`

List buckets in a namespace.

**Usage:**

```
hfs buckets list [NAMESPACE]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `NAMESPACE` | no | Namespace (falls back to `HF_NAMESPACE` env var) |

**Examples:**

```bash
# List buckets for a namespace
hfs buckets list my-org

# List buckets using environment variable
export HF_NAMESPACE=my-org
hfs buckets list
```

---

### `buckets info`

Show detailed information about a specific bucket.

**Usage:**

```
hfs buckets info BUCKET
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `BUCKET` | yes | Bucket identifier (`namespace/name`) |

**Example:**

```bash
hfs buckets info user/my-bucket
```

---

## Help System

Every command supports `--help` (or `help` as a subcommand):

```bash
# List all commands
hfs help

# Command-specific help
hfs help upload
hfs help delete
hfs help buckets

# Shorthand
hfs upload --help
hfs delete --help
```

---

## Output Formats

By default, commands output human-readable text. Pass `--json` or `--format json` for machine-readable output:

```bash
# Human-readable
hfs list user/my-bucket

# JSON machine output
hfs list user/my-bucket --json
hfs list user/my-bucket --format json
```

Some commands (`info`, `buckets info`) always output JSON.

The `--format` global option (`text` / `json`) is available on all commands. The `list` command has an additional `--format table` option for tabular output.

---

## Source Code Guide

The CLI source lives under `src/hugging_face_storage/cli/`.

### File Map

| File | Purpose |
|------|---------|
| `bin/hfs` | Entry point — `require`s the lib and calls `CLI.start(ARGV)` |
| `cli/cli.rb` | Main `CLI < Thor` class — defines commands, globals, dispatch |
| `cli/buckets_cli.rb` | `BucketsCLI < Thor` — subcommand for `buckets list` / `buckets info` |
| `cli/formatter.rb` | `CLIFormatter` module — table/JSON formatting, client construction |
| `cli/commands/transfer.rb` | `Transfer` module — `upload`, `download` implementations |
| `cli/commands/manage.rb` | `Manage` module — `delete`, `move`, `list`, `info` implementations |
| `cli/commands/copy_commands.rb` | `CopyCommands` module — `copy` implementation |
| `cli/commands/advanced.rb` | `Advanced` module — `snapshot`, `edit` implementations |
| `spec/.../cli/cli_spec.rb` | CLI spec — 567 lines covering all commands, options, errors |
| `spec/.../cli/buckets_cli_spec.rb` | BucketsCLI spec |
| `spec/.../cli/commands/copy_commands_spec.rb` | Copy commands spec |

### Architecture

```
CLI < Thor
├── upload, download          ← Transfer module
├── delete, move, list, info  ← Manage module
├── copy                      ← CopyCommands module
├── snapshot, edit            ← Advanced module
└── buckets (subcommand)      ← BucketsCLI
```

### How dispatch works

Each CLI method (e.g. `def upload`) calls a private `dispatch` method that uses Ruby's `UnboundMethod#bind_call` to invoke the implementation from the correct module. This avoids method resolution order ambiguity that would arise from including multiple modules:

```ruby
def dispatch(method_name, mod, *args)
  mod.instance_method(method_name).bind_call(self, *args)
end
```

### How the client is built

`CLIFormatter.build_client` handles authentication resolution:

1. Parse `BUCKET` into `namespace` and `name`
2. Use `--token` option, then `HF_TOKEN` env, then `~/.huggingface/token` file
3. Construct `HuggingFaceStorage::Client` with `log_level: :warn` (errors and warnings only)

### How output formatting works

The `format_or_say` helper checks `--json` / `--format`:

```ruby
def format_or_say(result)
  if options[:json] || options[:format] == "json"
    say CLIFormatter.format_json(result)
  else
    yield  # human-readable message
  end
end
```

`CLIFormatter` provides:
- `format_table(rows, headers)` — auto-width tabular output
- `format_json(data)` — `JSON.pretty_generate`
- `format_error(message, hint:)` — ANSI-colored error with optional yellow hint
- `format_output(data, format, headers:)` — dispatches to table or JSON

### Extending the CLI

To add a new command:

1. Define the implementation method in a new or existing module under `cli/commands/`
2. Declare the Thor command in `cli.rb` with `desc`, `option`, `def`
3. Call `dispatch(:method_name, ModuleName, *args)` inside the method
4. Add specs in `spec/hugging_face_storage/cli/`
