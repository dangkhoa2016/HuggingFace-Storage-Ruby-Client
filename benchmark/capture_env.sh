#!/bin/bash
# capture_env.sh — Snapshot build environment for CI regression investigation
#
# Usage:
#   bash benchmark/capture_env.sh                    # prints to stdout
#   bash benchmark/capture_env.sh > env_snapshot.txt # save to file
#
# Captures OS, compiler, Ruby, and native extension metadata
# to compare between environments where performance differs.

echo "=== Environment Snapshot ==="
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
echo ""

echo "--- OS ---"
uname -a
cat /etc/os-release 2>/dev/null || echo "(no /etc/os-release)"
echo ""

echo "--- CPU ---"
lscpu 2>/dev/null | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core|Socket|MHz|Cache' || echo "(lscpu not available)"
echo ""

echo "--- Memory ---"
free -h 2>/dev/null || echo "(free not available)"
echo ""

echo "--- Compiler (CC) ---"
echo "CC: ${CC:-gcc}"
${CC:-gcc} --version 2>/dev/null | head -1 || echo "(gcc not found)"
echo ""

echo "--- Ruby ---"
ruby --version
echo "RUBY_PLATFORM: ${RUBY_PLATFORM}"
echo "RbConfig::CONFIG['CC']: $(ruby -e "puts RbConfig::CONFIG['CC']" 2>/dev/null)"
echo "RbConfig::CONFIG['CFLAGS']: $(ruby -e "puts RbConfig::CONFIG['CFLAGS']" 2>/dev/null)"
echo "RbConfig::CONFIG['LDFLAGS']: $(ruby -e "puts RbConfig::CONFIG['LDFLAGS']" 2>/dev/null)"
echo "RbConfig::CONFIG['ARCHFLAGS']: $(ruby -e "puts RbConfig::CONFIG['ARCHFLAGS']" 2>/dev/null)"
echo "RbConfig::CONFIG['optimize_flag']: $(ruby -e "puts RbConfig::CONFIG['optimize_flag']" 2>/dev/null)"
echo ""

echo "--- Bundler ---"
bundle --version 2>/dev/null || echo "(bundler not found)"
echo ""

echo "--- Native Extension ---"
SO_PATH="src/hugging_face_storage/gearhash.so"
if [ -f "$SO_PATH" ]; then
  echo "gearhash.so: FOUND"
  echo "  Size: $(stat -c%s "$SO_PATH" 2>/dev/null || stat -f%z "$SO_PATH" 2>/dev/null) bytes"
  echo "  MD5: $(md5sum "$SO_PATH" 2>/dev/null | cut -d' ' -f1 || md5 "$SO_PATH" 2>/dev/null | awk '{print $NF}')"
  file "$SO_PATH" 2>/dev/null
  ldd "$SO_PATH" 2>/dev/null || echo "  (ldd not available or not ELF)"
else
  echo "gearhash.so: NOT FOUND"
fi
echo ""

echo "--- Compiled Sources ---"
HASH="unknown"
if command -v git &>/dev/null && [ -d .git ]; then
  HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi
echo "git HEAD: $HASH"
git log --oneline -3 2>/dev/null || echo "(not a git repo)"
echo ""

echo "--- Benchmark Runner ---"
ruby -e "puts 'Ruby thread count: ' + RbConfig::CONFIG['rb_thread_call_without_gvl'].to_s rescue nil"
ruby -e "puts 'Processors: ' + Etc.nprocessors.to_s" 2>/dev/null || true
echo ""

echo "=== End Snapshot ==="
