#include "ruby.h"
#include "ruby/thread.h"
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

#define GEAR_HASH_MASK 0xFFFFFFFFFFFFFFFFULL
#define MAX_BOUNDARY_STACK 4096
#define MAX_PTHREADS 8

/* --------------------------------------------------------------------------
 * Two-pass CDC chunking: scan boundaries, then build Ruby output array.
 *
 * Pass 1 (scan_boundaries): Pure C loop, zero Ruby object allocation.
 *   Single tight loop with branch hints for the common case
 *   (no boundary detected).
 *
 * Pass 2 (build_chunks): Single batch allocation of Ruby Array.
 *   - Pre-allocates the output array with known size
 *   - Fills with [start, end] pairs from pre-computed boundaries
 *
 * Table caching: The 256-entry lookup table is copied once per call.
 * For repeated calls with the same table, a cached C-level copy is
 * maintained in a Ruby Hash keyed by table object_id.
 * -------------------------------------------------------------------------- */

/* --------------------------------------------------------------------------
 * Gearhash table cache: avoids copying 256 entries from Ruby Array on
 * every cdc_chunk call. Keyed by table object_id (frozen arrays are stable).
 * -------------------------------------------------------------------------- */
static VALUE table_cache = Qnil;

static void ensure_table_cache(void) {
    if (table_cache == Qnil) {
        table_cache = rb_hash_new();
        rb_global_variable(&table_cache);
    }
}

/* Get cached C table for a given Ruby Array. Copies to dst if cached,
 * otherwise copies from Ruby Array and caches the result. */
static void get_cached_table(uint64_t *dst, VALUE ruby_table) {
    ensure_table_cache();
    VALUE key = rb_obj_id(ruby_table);
    VALUE cached = rb_hash_aref(table_cache, key);

    if (cached != Qnil) {
        /* Cache hit: copy pre-computed C array */
        memcpy(dst, (const uint64_t *)RSTRING_PTR(cached), 256 * sizeof(uint64_t));
    } else {
        /* Cache miss: copy from Ruby Array, store in cache */
        for (int i = 0; i < 256; i++) {
            dst[i] = NUM2ULL(rb_ary_entry(ruby_table, i));
        }
        VALUE blob = rb_str_new((const char *)dst, 256 * sizeof(uint64_t));
        rb_hash_aset(table_cache, key, blob);
    }
}

/* --------------------------------------------------------------------------
 * Pass 1: Single-loop boundary scan with branch hints.
 *
 * The common case is "no boundary" — the gear hash keeps rolling.
 * __builtin_expect tells the compiler to optimize for this path,
 * keeping the branch predictor happy without loop-splitting overhead.
 * -------------------------------------------------------------------------- */
static long scan_boundaries(
    const uint8_t *bytes, long len,
    const uint64_t *tbl, uint64_t mask,
    long min_chunk, long max_chunk,
    long *out_boundaries
) {
    uint64_t h = 0;
    long start = 0;
    long n = 0;

    for (long i = 0; i < len; i++) {
        h = ((h << 1) + tbl[bytes[i]]) & GEAR_HASH_MASK;
        long size = i - start + 1;

        if (__builtin_expect(size >= min_chunk, 0)) {
            if (__builtin_expect(size >= max_chunk || (h & mask) == 0, 0)) {
                out_boundaries[n++] = i + 1;
                start = i + 1;
                h = 0;
            }
        }
    }

    return n;
}

/* --------------------------------------------------------------------------
 * Pass 2: Build Ruby Array from pre-computed boundary positions.
 * Allocates a single Array and fills it with [start, end] pairs.
 * Uses batch allocation to minimize Ruby object overhead. */
static VALUE build_chunks_from_boundaries(
    const long *boundaries, long count, long data_len
) {
    /* Pre-allocate: count boundaries → count + 1 chunks (including final) */
    VALUE chunks = rb_ary_new2(count + 1);
    long start = 0;

    for (long i = 0; i < count; i++) {
        rb_ary_push(chunks, rb_ary_new_from_args(2, LONG2NUM(start), LONG2NUM(boundaries[i])));
        start = boundaries[i];
    }

    /* Final chunk: [last_boundary, data_len) */
    rb_ary_push(chunks, rb_ary_new_from_args(2, LONG2NUM(start), LONG2NUM(data_len)));
    return chunks;
}

/* --------------------------------------------------------------------------
 * Optimized CDC chunk: two-pass approach with table caching.
 * Ruby API: Gearhash.cdc_chunk(data, mask, min_chunk, max_chunk, table)
 *        -> Array[[Integer, Integer]] */
static VALUE rb_gearhash_cdc_chunk(VALUE self, VALUE data, VALUE mask_val,
                                   VALUE min_c, VALUE max_c, VALUE table) {
    Check_Type(data, T_STRING);
    Check_Type(table, T_ARRAY);

    const uint8_t *bytes = (const uint8_t *)RSTRING_PTR(data);
    long len = RSTRING_LEN(data);
    uint64_t mask = NUM2ULL(mask_val);
    long min_chunk = NUM2LONG(min_c);
    long max_chunk = NUM2LONG(max_c);

    /* Cached table lookup — avoids 256x NUM2ULL + rb_ary_entry on repeat calls */
    uint64_t tbl[256];
    get_cached_table(tbl, table);

    /* Fast path: data fits in a single chunk */
    if (len <= min_chunk) {
        VALUE chunks = rb_ary_new2(1);
        rb_ary_push(chunks, rb_ary_new_from_args(2, INT2FIX(0), LONG2NUM(len)));
        return chunks;
    }

    /* Allocate boundary buffer on stack for small data, heap for large */
    long stack_buf[MAX_BOUNDARY_STACK];
    long *boundaries = stack_buf;
    int heap_allocated = 0;

    long max_boundaries = len / min_chunk + 1;
    if (max_boundaries > MAX_BOUNDARY_STACK) {
        boundaries = ALLOC_N(long, max_boundaries);
        heap_allocated = 1;
    }

    /* Pass 1: two-phase scan — zero Ruby allocations */
    long count = scan_boundaries(bytes, len, tbl, mask, min_chunk, max_chunk, boundaries);

    /* Pass 2: build output — single batch allocation */
    VALUE chunks = build_chunks_from_boundaries(boundaries, count, len);

    if (heap_allocated) {
        xfree(boundaries);
    }

    return chunks;
}

/* --------------------------------------------------------------------------
 * Streaming CDC state (CdcState class).
 * Maintains rolling hash state across multiple feed() calls.
 * Uses a fixed pending buffer to avoid per-chunk allocation.
 * Table is cached in the struct — no Ruby Array access during feed().
 * -------------------------------------------------------------------------- */

typedef struct {
    uint64_t gear_h;
    uint8_t pending[131072]; /* 128 KiB pending buffer */
    long pending_len;
    uint64_t tbl[256];
    uint64_t mask;
    long min_chunk;
    long max_chunk;
} cdc_state;

static void cdc_state_mark(void *ptr) {
    (void)ptr;
}

static void cdc_state_free(void *ptr) {
    xfree(ptr);
}

static size_t cdc_state_memsize(const void *ptr) {
    (void)ptr;
    return sizeof(cdc_state);
}

static const rb_data_type_t cdc_state_type = {
    "HuggingFaceStorage::Gearhash::CdcState",
    { cdc_state_mark, cdc_state_free, cdc_state_memsize },
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE rb_gearhash_cdc_state_alloc(VALUE klass) {
    cdc_state *state = ALLOC_N(cdc_state, 1);
    state->gear_h = 0;
    state->pending_len = 0;
    return TypedData_Wrap_Struct(klass, &cdc_state_type, state);
}

static VALUE rb_gearhash_cdc_state_init(VALUE self, VALUE table, VALUE mask_val,
                                         VALUE min_c, VALUE max_c) {
    Check_Type(table, T_ARRAY);
    cdc_state *state;
    TypedData_Get_Struct(self, cdc_state, &cdc_state_type, state);

    /* Use cached table copy — same mechanism as cdc_chunk */
    get_cached_table(state->tbl, table);

    state->mask = NUM2ULL(mask_val);
    state->min_chunk = NUM2LONG(min_c);
    state->max_chunk = NUM2LONG(max_c);
    state->gear_h = 0;
    state->pending_len = 0;
    return self;
}

static VALUE rb_gearhash_cdc_state_feed(VALUE self, VALUE data) {
    Check_Type(data, T_STRING);
    cdc_state *state;
    TypedData_Get_Struct(self, cdc_state, &cdc_state_type, state);

    const uint8_t *bytes = (const uint8_t *)RSTRING_PTR(data);
    long len = RSTRING_LEN(data);
    VALUE chunks = rb_ary_new();

    long start = 0;

    for (long i = 0; i < len; i++) {
        state->gear_h = ((state->gear_h << 1) + state->tbl[bytes[i]]) & GEAR_HASH_MASK;
        long size = state->pending_len + (i - start + 1);

        if (__builtin_expect(size >= state->min_chunk, 0)) {
            if (__builtin_expect(size >= state->max_chunk || (state->gear_h & state->mask) == 0, 0)) {
                VALUE chunk = rb_str_new(NULL, size);
                char *out = RSTRING_PTR(chunk);
                if (state->pending_len > 0) {
                    memcpy(out, state->pending, state->pending_len);
                }
                memcpy(out + state->pending_len, bytes + start, i - start + 1);
                rb_str_set_len(chunk, size);
                rb_ary_push(chunks, chunk);
                state->pending_len = 0;
                state->gear_h = 0;
                start = i + 1;
            }
        }
    }

    if (start < len) {
        long remain = len - start;
        memcpy(state->pending + state->pending_len, bytes + start, remain);
        state->pending_len += remain;
    }

    return chunks;
}

static VALUE rb_gearhash_cdc_state_finalize(VALUE self) {
    cdc_state *state;
    TypedData_Get_Struct(self, cdc_state, &cdc_state_type, state);

    VALUE chunks = rb_ary_new();
    if (state->pending_len > 0) {
        VALUE chunk = rb_str_new(NULL, state->pending_len);
        memcpy(RSTRING_PTR(chunk), state->pending, state->pending_len);
        rb_str_set_len(chunk, state->pending_len);
        rb_ary_push(chunks, chunk);
    }
    state->pending_len = 0;
    state->gear_h = 0;
    return chunks;
}

/* --------------------------------------------------------------------------
 * Xorb XOR: byte-wise XOR of two 32-byte strings.
 * Used by XorbHashTree for Merkle-style tree reduction.
 * -------------------------------------------------------------------------- */

static VALUE rb_gearhash_xorb_xor(VALUE self, VALUE a, VALUE b) {
    Check_Type(a, T_STRING);
    Check_Type(b, T_STRING);

    long len_a = RSTRING_LEN(a);
    long len_b = RSTRING_LEN(b);

    if (len_a != 32 || len_b != 32) {
        rb_raise(rb_eArgError, "both arguments must be 32-byte strings");
    }

    const uint8_t *bytes_a = (const uint8_t *)RSTRING_PTR(a);
    const uint8_t *bytes_b = (const uint8_t *)RSTRING_PTR(b);

    VALUE result = rb_str_new(NULL, 32);
    uint8_t *out = (uint8_t *)RSTRING_PTR(result);

    for (long i = 0; i < 32; i++) {
        out[i] = bytes_a[i] ^ bytes_b[i];
    }

    return result;
}

/* --------------------------------------------------------------------------
 * Xorb serialization from ranges: write chunk data directly from source
 * buffer to a pre-allocated output buffer. Eliminates per-chunk String
 * allocation that would otherwise be needed for intermediate copies.
 *
 * Ruby API: Gearhash.serialize_xorb_from_ranges(data, ranges) -> String
 * -------------------------------------------------------------------------- */

static VALUE rb_gearhash_serialize_xorb_from_ranges(VALUE self, VALUE data, VALUE ranges) {
    Check_Type(data, T_STRING);
    Check_Type(ranges, T_ARRAY);

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    long num_chunks = RARRAY_LEN(ranges);

    /* Calculate total output size: sum of (8-byte header + chunk data) */
    long total_size = 0;
    for (long i = 0; i < num_chunks; i++) {
        VALUE pair = rb_ary_entry(ranges, i);
        long start = NUM2LONG(rb_ary_entry(pair, 0));
        long end = NUM2LONG(rb_ary_entry(pair, 1));
        long chunk_len = end - start;

        if (chunk_len > 0xFFFFFF) {
            rb_raise(rb_eArgError, "chunk size %ld exceeds 24-bit limit", chunk_len);
        }

        total_size += 8 + chunk_len; /* CHUNK_HEADER_SIZE = 8 */
    }

    /* Single allocation for entire output */
    VALUE result = rb_str_new(NULL, total_size);
    char *out = RSTRING_PTR(result);
    long offset = 0;

    for (long i = 0; i < num_chunks; i++) {
        VALUE pair = rb_ary_entry(ranges, i);
        long start = NUM2LONG(rb_ary_entry(pair, 0));
        long end = NUM2LONG(rb_ary_entry(pair, 1));
        long chunk_len = end - start;

        /* Header: \x00 + 3-byte LE size + \x00 + 3-byte LE size */
        uint8_t sb[3];
        sb[0] = (uint8_t)(chunk_len & 0xFF);
        sb[1] = (uint8_t)((chunk_len >> 8) & 0xFF);
        sb[2] = (uint8_t)((chunk_len >> 16) & 0xFF);

        out[offset] = '\x00';
        memcpy(out + offset + 1, sb, 3);
        out[offset + 4] = '\x00';
        memcpy(out + offset + 5, sb, 3);
        offset += 8;

        /* Chunk data: memcpy from source buffer */
        memcpy(out + offset, src + start, chunk_len);
        offset += chunk_len;
    }

    rb_str_set_len(result, total_size);
    return result;
}

/* --------------------------------------------------------------------------
 * Full shard builder: constructs the complete shard metadata binary in a
 * single pass with zero Ruby object allocation per chunk. Replaces the
 * Ruby build_shard + build_file_info_section + build_xorb_info_section +
 * assemble_shard chain.
 *
 * Ruby API: Gearhash.build_shard(
 *   file_hash, sha256, rep_xorb_hashes, rep_lengths, rep_index_starts,
 *   rep_index_ends, rep_range_hashes,
 *   xorb_hash, chunk_hashes, chunk_lengths, xorb_serialized_size
 * ) -> String
 * -------------------------------------------------------------------------- */

#define SHARD_TAG_SIZE 32
#define SHARD_HASH_LEN 32
#define SHARD_UINT32_SIZE 4
#define SHARD_UINT64_SIZE 8
#define SHARD_HEADER_SIZE 48
#define SHARD_FOOTER_SIZE 200
#define SHARD_BOOKEND_SIZE 48
#define SHARD_FILE_FLAGS 0xC0000000

static const uint8_t SHARD_TAG_DATA[SHARD_TAG_SIZE] = {
    72, 70, 82, 101, 112, 111, 77, 101, 116, 97, 68, 97, 116, 97, 0, 85,
    105, 103, 69, 106, 123, 129, 87, 131, 165, 189, 217, 92, 205, 209, 74, 169
};

static inline void write_le32(uint8_t *buf, uint32_t val) {
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    buf[2] = (uint8_t)((val >> 16) & 0xFF);
    buf[3] = (uint8_t)((val >> 24) & 0xFF);
}

static inline void write_le64(uint8_t *buf, uint64_t val) {
    buf[0] = (uint8_t)(val & 0xFF);
    buf[1] = (uint8_t)((val >> 8) & 0xFF);
    buf[2] = (uint8_t)((val >> 16) & 0xFF);
    buf[3] = (uint8_t)((val >> 24) & 0xFF);
    buf[4] = (uint8_t)((val >> 32) & 0xFF);
    buf[5] = (uint8_t)((val >> 40) & 0xFF);
    buf[6] = (uint8_t)((val >> 48) & 0xFF);
    buf[7] = (uint8_t)((val >> 56) & 0xFF);
}

/* --------------------------------------------------------------------------
 * Xorb info section builder (standalone, for backward compat)
 * -------------------------------------------------------------------------- */
static VALUE rb_gearhash_build_xorb_info(VALUE self, VALUE xorb_hash,
                                         VALUE chunk_hashes, VALUE chunk_lengths,
                                         VALUE rb_xorb_serialized_size) {
    Check_Type(xorb_hash, T_STRING);
    Check_Type(chunk_hashes, T_ARRAY);
    Check_Type(chunk_lengths, T_ARRAY);

    if (RSTRING_LEN(xorb_hash) != SHARD_HASH_LEN) {
        rb_raise(rb_eArgError, "xorb_hash must be 32 bytes");
    }

    long num_chunks = RARRAY_LEN(chunk_hashes);
    if (RARRAY_LEN(chunk_lengths) != num_chunks) {
        rb_raise(rb_eArgError, "chunk_hashes and chunk_lengths must have same length");
    }

    uint32_t xorb_serialized_size = (uint32_t)NUM2UINT(rb_xorb_serialized_size);

    uint64_t total_raw = 0;
    for (long i = 0; i < num_chunks; i++) {
        total_raw += (uint64_t)NUM2ULONG(rb_ary_entry(chunk_lengths, i));
    }

    long section_size = SHARD_HASH_LEN + SHARD_UINT32_SIZE * 4
                        + num_chunks * (SHARD_HASH_LEN + SHARD_UINT32_SIZE * 2 + SHARD_UINT64_SIZE);

    VALUE result = rb_str_new(NULL, section_size);
    uint8_t *out = (uint8_t *)RSTRING_PTR(result);
    long pos = 0;

    memcpy(out + pos, RSTRING_PTR(xorb_hash), SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;

    write_le32(out + pos, 0);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, (uint32_t)num_chunks);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, (uint32_t)total_raw);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, xorb_serialized_size);
    pos += SHARD_UINT32_SIZE;

    uint32_t offset = 0;
    for (long i = 0; i < num_chunks; i++) {
        VALUE ch = rb_ary_entry(chunk_hashes, i);
        if (RSTRING_LEN(ch) != SHARD_HASH_LEN) {
            rb_raise(rb_eArgError, "chunk hash at index %ld must be 32 bytes", i);
        }
        memcpy(out + pos, RSTRING_PTR(ch), SHARD_HASH_LEN);
        pos += SHARD_HASH_LEN;

        write_le32(out + pos, offset);
        pos += SHARD_UINT32_SIZE;
        uint32_t chunk_len = (uint32_t)NUM2UINT(rb_ary_entry(chunk_lengths, i));
        write_le32(out + pos, chunk_len);
        pos += SHARD_UINT32_SIZE;
        write_le64(out + pos, 0);
        pos += SHARD_UINT64_SIZE;

        offset += chunk_len;
    }

    rb_str_set_len(result, pos);
    return result;
}

/* --------------------------------------------------------------------------
 * Full shard builder: zero-allocation per-chunk shard construction.
 * Accepts pre-separated representation and chunk arrays from Ruby.
 * -------------------------------------------------------------------------- */
static VALUE rb_gearhash_build_full_shard(VALUE self,
                                          VALUE file_hash, VALUE sha256,
                                          VALUE rep_xorb_hashes, VALUE rep_lengths,
                                          VALUE rep_index_starts, VALUE rep_index_ends,
                                          VALUE rep_range_hashes,
                                          VALUE xorb_hash, VALUE chunk_hashes,
                                          VALUE chunk_lengths,
                                          VALUE rb_xorb_serialized_size) {
    /* Validate inputs */
    Check_Type(file_hash, T_STRING);
    Check_Type(sha256, T_STRING);
    Check_Type(rep_xorb_hashes, T_ARRAY);
    Check_Type(rep_lengths, T_ARRAY);
    Check_Type(rep_index_starts, T_ARRAY);
    Check_Type(rep_index_ends, T_ARRAY);
    Check_Type(rep_range_hashes, T_ARRAY);
    Check_Type(xorb_hash, T_STRING);
    Check_Type(chunk_hashes, T_ARRAY);
    Check_Type(chunk_lengths, T_ARRAY);

    if (RSTRING_LEN(file_hash) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "file_hash must be 32 bytes");
    if (RSTRING_LEN(sha256) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "sha256 must be 32 bytes");
    if (RSTRING_LEN(xorb_hash) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "xorb_hash must be 32 bytes");

    long num_reps = RARRAY_LEN(rep_xorb_hashes);
    long num_chunks = RARRAY_LEN(chunk_hashes);
    uint32_t xorb_serialized_size = (uint32_t)NUM2UINT(rb_xorb_serialized_size);

    /* Compute total_raw */
    uint64_t total_raw = 0;
    for (long i = 0; i < num_chunks; i++) {
        total_raw += (uint64_t)NUM2ULONG(rb_ary_entry(chunk_lengths, i));
    }

    /* File info size: 32(hash) + 4(flags) + 4(rep_count) + 8(reserved) + reps * (32+4+4+4+4+32+8+8) + 32(sha256) + 8+8 */
    long rep_entry_size = SHARD_HASH_LEN + SHARD_UINT32_SIZE * 4 + SHARD_HASH_LEN + SHARD_UINT64_SIZE * 2;
    uint64_t file_info_size = (uint64_t)(SHARD_HASH_LEN + SHARD_UINT32_SIZE * 2 + SHARD_UINT64_SIZE)
                              + (uint64_t)num_reps * (uint64_t)rep_entry_size
                              + (uint64_t)(SHARD_HASH_LEN + SHARD_UINT64_SIZE * 2);

    /* Xorb info size: 32(hash) + 4*4(header) + chunks * (32+4+4+8) */
    uint64_t xorb_info_size = (uint64_t)(SHARD_HASH_LEN + SHARD_UINT32_SIZE * 4)
                              + (uint64_t)num_chunks * (uint64_t)(SHARD_HASH_LEN + SHARD_UINT32_SIZE * 2 + SHARD_UINT64_SIZE);

    /* Compute offsets */
    uint64_t file_info_offset = SHARD_HEADER_SIZE;
    uint64_t xorb_info_offset = file_info_offset + file_info_size + SHARD_BOOKEND_SIZE;
    uint64_t footer_offset = xorb_info_offset + xorb_info_size + SHARD_BOOKEND_SIZE;
    uint64_t total_size = footer_offset + SHARD_FOOTER_SIZE;

    /* Single allocation for entire output, zero-initialized.
     * Required because some sections (bookend padding, footer reserved
     * fields) are left as implicit zeros from the initial memset. */
    VALUE result = rb_str_new(NULL, (long)total_size);
    uint8_t *out = (uint8_t *)RSTRING_PTR(result);
    memset(out, 0, (long)total_size);
    long pos = 0;

    /* ═══ Shard Header (48 bytes) ═══ */
    memcpy(out + pos, SHARD_TAG_DATA, SHARD_TAG_SIZE);
    pos += SHARD_TAG_SIZE;
    write_le64(out + pos, 2);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, SHARD_FOOTER_SIZE);
    pos += SHARD_UINT64_SIZE;
    /* pos = 48, rest is zeros from memset */

    /* ═══ File Info Section ═══ */
    memcpy(out + pos, RSTRING_PTR(file_hash), SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;
    write_le32(out + pos, SHARD_FILE_FLAGS);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, (uint32_t)num_reps);
    pos += SHARD_UINT32_SIZE;
    write_le64(out + pos, 0);
    pos += SHARD_UINT64_SIZE;

    /* Representation entries */
    for (long i = 0; i < num_reps; i++) {
        VALUE rxh = rb_ary_entry(rep_xorb_hashes, i);
        if (RSTRING_LEN(rxh) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "rep xorb_hash at %ld must be 32", i);
        memcpy(out + pos, RSTRING_PTR(rxh), SHARD_HASH_LEN);
        pos += SHARD_HASH_LEN;

        write_le32(out + pos, 0);
        pos += SHARD_UINT32_SIZE;
        write_le32(out + pos, (uint32_t)NUM2UINT(rb_ary_entry(rep_lengths, i)));
        pos += SHARD_UINT32_SIZE;
        write_le32(out + pos, (uint32_t)NUM2UINT(rb_ary_entry(rep_index_starts, i)));
        pos += SHARD_UINT32_SIZE;
        write_le32(out + pos, (uint32_t)NUM2UINT(rb_ary_entry(rep_index_ends, i)));
        pos += SHARD_UINT32_SIZE;

        VALUE rrh = rb_ary_entry(rep_range_hashes, i);
        if (RSTRING_LEN(rrh) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "rep range_hash at %ld must be 32", i);
        memcpy(out + pos, RSTRING_PTR(rrh), SHARD_HASH_LEN);
        pos += SHARD_HASH_LEN;

        write_le64(out + pos, 0);
        pos += SHARD_UINT64_SIZE;
        write_le64(out + pos, 0);
        pos += SHARD_UINT64_SIZE;
    }

    /* SHA256 + padding */
    memcpy(out + pos, RSTRING_PTR(sha256), SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;
    write_le64(out + pos, 0);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, 0);
    pos += SHARD_UINT64_SIZE;

    /* ═══ Bookend (48 bytes) ═══ */
    memset(out + pos, 0xFF, SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;
    pos += 16; /* zeros from memset */

    /* ═══ Xorb Info Section ═══ */
    memcpy(out + pos, RSTRING_PTR(xorb_hash), SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;
    write_le32(out + pos, 0);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, (uint32_t)num_chunks);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, (uint32_t)total_raw);
    pos += SHARD_UINT32_SIZE;
    write_le32(out + pos, xorb_serialized_size);
    pos += SHARD_UINT32_SIZE;

    uint32_t xoffset = 0;
    for (long i = 0; i < num_chunks; i++) {
        VALUE ch = rb_ary_entry(chunk_hashes, i);
        if (RSTRING_LEN(ch) != SHARD_HASH_LEN) rb_raise(rb_eArgError, "chunk hash at %ld must be 32", i);
        memcpy(out + pos, RSTRING_PTR(ch), SHARD_HASH_LEN);
        pos += SHARD_HASH_LEN;

        write_le32(out + pos, xoffset);
        pos += SHARD_UINT32_SIZE;
        uint32_t clen = (uint32_t)NUM2UINT(rb_ary_entry(chunk_lengths, i));
        write_le32(out + pos, clen);
        pos += SHARD_UINT32_SIZE;
        write_le64(out + pos, 0);
        pos += SHARD_UINT64_SIZE;

        xoffset += clen;
    }

    /* ═══ Bookend (48 bytes) ═══ */
    memset(out + pos, 0xFF, SHARD_HASH_LEN);
    pos += SHARD_HASH_LEN;
    pos += 16;

    /* ═══ Footer (200 bytes) ═══ */
    write_le64(out + pos, 1);                         /* version */
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, file_info_offset);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, xorb_info_offset);
    pos += SHARD_UINT64_SIZE;
    pos += 48; /* zeros (3 x uint64 reserved) */
    pos += 32; /* zeros */
    write_le64(out + pos, (uint64_t)time(NULL));      /* timestamp */
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, 0);
    pos += SHARD_UINT64_SIZE;
    pos += 48; /* zeros */
    write_le64(out + pos, (uint64_t)xorb_serialized_size);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, total_raw);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, total_raw);
    pos += SHARD_UINT64_SIZE;
    write_le64(out + pos, footer_offset);
    pos += SHARD_UINT64_SIZE;
    pos += 32; /* trailing zeros */

    rb_str_set_len(result, (long)total_size);
    return result;
}

/* --------------------------------------------------------------------------
 * BLAKE3 batch keyed hashing from ranges — single FFI call, no Ruby loop.
 *
 * Loads the blake3 shared library via dlopen on first call, then processes
 * all chunks in a tight C loop. Each chunk is hashed independently with
 * the same key, producing 32-byte output per chunk.
 *
 * Ruby equivalent:
 *   ranges.map { |s, e| blake3_keyed(key, data.byteslice(s, e - s)) }.join
 *
 * Returns: Ruby String containing concatenated 32-byte hashes.
 * -------------------------------------------------------------------------- */

#define BLAKE3_HASHER_SIZE 2048
#define BLAKE3_HASH_LEN 32

typedef void (*blake3_init_keyed_fn)(void *hasher, const void *key);
typedef void (*blake3_update_fn)(void *hasher, const void *input, size_t input_len);
typedef void (*blake3_finalize_fn)(void *hasher, void *out, size_t out_len);

static blake3_init_keyed_fn blake3_init_keyed_ptr = NULL;
static blake3_update_fn    blake3_update_ptr      = NULL;
static blake3_finalize_fn  blake3_finalize_ptr    = NULL;
static int blake3_loaded = 0;

/* Attempt to load the blake3 shared library via dlopen.
 * Uses Ruby's Gem.find_files to discover the path dynamically,
 * so it works across Ruby versions and gem install locations.
 * Returns 1 on success, 0 on failure. */
static int blake3_ensure_loaded(void) {
    void *handle;
    if (blake3_loaded) return 1;

    /* Use Ruby API: Gem.find_files("digest/blake3/blake3.so") */
    VALUE mGem = rb_const_get(rb_cObject, rb_intern("Gem"));
    VALUE candidates = rb_funcall(mGem, rb_intern("find_files"), 1,
                                  rb_str_new2("digest/blake3/blake3.so"));
    long num = RARRAY_LEN(candidates);
    for (long i = 0; i < num; i++) {
        VALUE path = rb_ary_entry(candidates, i);
        const char *cpath = StringValueCStr(path);
        handle = dlopen(cpath, RTLD_NOW);
        if (handle) goto found;
    }

    return 0;

found:
    blake3_init_keyed_ptr = (blake3_init_keyed_fn)dlsym(handle, "blake3_hasher_init_keyed");
    blake3_update_ptr     = (blake3_update_fn)dlsym(handle, "blake3_hasher_update");
    blake3_finalize_ptr   = (blake3_finalize_fn)dlsym(handle, "blake3_hasher_finalize");

    if (!blake3_init_keyed_ptr || !blake3_update_ptr || !blake3_finalize_ptr) {
        dlclose(handle);
        return 0;
    }

    blake3_loaded = 1;
    return 1;
}

/* Hash a single chunk from source buffer at given offset/length.
 * Writes the 32-byte hash to `out`. Uses stack-allocated hasher. */
static void blake3_hash_chunk(
    const void *key,
    const char *source_ptr, long offset, long length,
    char *out
) {
    char hasher_buf[BLAKE3_HASHER_SIZE];

    blake3_init_keyed_ptr(hasher_buf, key);
    blake3_update_ptr(hasher_buf, source_ptr + offset, (size_t)length);
    blake3_finalize_ptr(hasher_buf, out, BLAKE3_HASH_LEN);
}

/* --------------------------------------------------------------------------
 * Parallel BLAKE3 hashing via pthreads.
 *
 * Each thread processes a contiguous range of chunks, providing better
 * cache locality than round-robin distribution. The work is split into
 * num_threads contiguous blocks, each handled by a single pthread.
 *
 * Thread safety: blake3_hash_chunk uses only stack-allocated buffers and
 * writes to caller-provided output pointers. The blake3 function pointers
 * are read-only after initialization. No Ruby API calls are made from
 * worker threads (no GVL required).
 * -------------------------------------------------------------------------- */

typedef struct {
    long chunk_start_idx;
    long chunk_end_idx;
    const char *source_ptr;
    const char *key_ptr;
    const long *chunk_offsets;
    char *hash_ptr;
} blake3_thread_work_t;

static void *blake3_thread_worker(void *arg) {
    blake3_thread_work_t *work = (blake3_thread_work_t *)arg;

    for (long i = work->chunk_start_idx; i < work->chunk_end_idx; i++) {
        long start = work->chunk_offsets[i];
        long end   = work->chunk_offsets[i + 1];
        blake3_hash_chunk(work->key_ptr, work->source_ptr, start, end - start,
                          work->hash_ptr + (i * BLAKE3_HASH_LEN));
    }

    return NULL;
}

typedef struct {
    long num_chunks;
    const char *source_ptr;
    const char *key_ptr;
    const long *chunk_offsets;
    char *hash_ptr;
    int num_threads;
} parallel_blake3_ctx;

/* Worker function for rb_thread_call_without_gvl.
 * Runs entirely in C — no Ruby API calls, no GVL needed. */
static void *parallel_blake3_without_gvl(void *args) {
    parallel_blake3_ctx *ctx = (parallel_blake3_ctx *)args;

    int n = ctx->num_threads;
    if (n > ctx->num_chunks) n = (int)ctx->num_chunks;
    if (n <= 1) {
        /* Sequential fallback for single thread or single chunk */
        for (long i = 0; i < ctx->num_chunks; i++) {
            long start = ctx->chunk_offsets[i];
            long end   = ctx->chunk_offsets[i + 1];
            blake3_hash_chunk(ctx->key_ptr, ctx->source_ptr, start, end - start,
                              ctx->hash_ptr + (i * BLAKE3_HASH_LEN));
        }
        return NULL;
    }

    pthread_t threads[MAX_PTHREADS];
    blake3_thread_work_t work[MAX_PTHREADS];

    /* Split chunks into n contiguous blocks for cache locality */
    long base = ctx->num_chunks / n;
    long remainder = ctx->num_chunks % n;
    long offset = 0;

    for (int t = 0; t < n; t++) {
        long count = base + (t < remainder ? 1 : 0);
        work[t].chunk_start_idx = offset;
        work[t].chunk_end_idx   = offset + count;
        work[t].source_ptr      = ctx->source_ptr;
        work[t].key_ptr         = ctx->key_ptr;
        work[t].chunk_offsets   = ctx->chunk_offsets;
        work[t].hash_ptr        = ctx->hash_ptr;

        pthread_create(&threads[t], NULL, blake3_thread_worker, &work[t]);
        offset += count;
    }

    for (int t = 0; t < n; t++) {
        pthread_join(threads[t], NULL);
    }

    return NULL;
}

/* Determine optimal thread count based on CPU cores and chunk count.
 * Returns a value in [1, min(nprocs, num_chunks, MAX_PTHREADS)]. */
static int optimal_thread_count(long num_chunks) {
    int nprocs = 1;
#ifdef _SC_NPROCESSORS_ONLN
    long raw = sysconf(_SC_NPROCESSORS_ONLN);
    if (raw > 0) nprocs = (int)raw;
#endif
    int n = nprocs;
    if (n > (int)num_chunks) n = (int)num_chunks;
    if (n > MAX_PTHREADS) n = MAX_PTHREADS;
    return n;
}

/* Ruby-callable: Gearhash.blake3_batch_keyed_from_ranges(source, ranges, key) */
static VALUE rb_gearhash_blake3_batch_keyed_from_ranges(
    VALUE self, VALUE source, VALUE ranges, VALUE key
) {
    (void)self;

    if (!blake3_ensure_loaded()) {
        rb_raise(rb_eRuntimeError, "blake3 shared library not found");
    }

    const char *source_ptr = RSTRING_PTR(source);
    long num_ranges = RARRAY_LEN(ranges);

    if (num_ranges == 0) {
        return rb_str_new2("");
    }

    /* Pre-allocate output string for all concatenated hashes */
    VALUE result = rb_str_new(NULL, num_ranges * BLAKE3_HASH_LEN);
    char *out_ptr = RSTRING_PTR(result);

    for (long i = 0; i < num_ranges; i++) {
        VALUE pair = rb_ary_entry(ranges, i);
        long start = NUM2LONG(rb_ary_entry(pair, 0));
        long end   = NUM2LONG(rb_ary_entry(pair, 1));
        long length = end - start;

        blake3_hash_chunk(RSTRING_PTR(key), source_ptr, start, length,
                          out_ptr + (i * BLAKE3_HASH_LEN));
    }

    return result;
}

/* --------------------------------------------------------------------------
 * Combined CDC chunking + BLAKE3 hashing — single C call, no Ruby loop.
 *
 * Performs content-defined chunking and immediately computes BLAKE3 keyed
 * hash for each chunk, returning both the chunk ranges and concatenated
 * hashes in a single call.
 *
 * Ruby API: Gearhash.cdc_and_hash(data, table, key, mask, min_chunk, max_chunk)
 *        -> [Array[[Integer, Integer]], String]
 *
 * The ranges Array and concatenated hashes String are returned as a
 * two-element Ruby Array. Each chunk's hash is 32 bytes, so the hashes
 * string length is num_chunks * 32.
 * -------------------------------------------------------------------------- */
static VALUE rb_gearhash_cdc_and_hash(
    VALUE self, VALUE data, VALUE table, VALUE key,
    VALUE mask_val, VALUE min_c, VALUE max_c
) {
    (void)self;
    Check_Type(data, T_STRING);
    Check_Type(table, T_ARRAY);

    if (!blake3_ensure_loaded()) {
        rb_raise(rb_eRuntimeError, "blake3 shared library not found");
    }

    const uint8_t *bytes = (const uint8_t *)RSTRING_PTR(data);
    long len = RSTRING_LEN(data);
    uint64_t mask = NUM2ULL(mask_val);
    long min_chunk = NUM2LONG(min_c);
    long max_chunk = NUM2LONG(max_c);

    /* Step 1: Scan boundaries (pure C, no Ruby objects) */
    long stack_boundaries[MAX_BOUNDARY_STACK];
    long *boundaries = stack_boundaries;
    long heap_size = 0;
    long max_boundaries = len / min_chunk + 1;

    if (max_boundaries > MAX_BOUNDARY_STACK) {
        boundaries = (long *)xmalloc(max_boundaries * sizeof(long));
        heap_size = max_boundaries;
    }

    uint64_t tbl[256];
    get_cached_table(tbl, table);

    long num_boundaries = scan_boundaries(bytes, len, tbl, mask, min_chunk, max_chunk, boundaries);

    /* Step 2: Build chunk offset array (cumulative boundaries) */
    long num_chunks = num_boundaries + 1;
    long *chunk_offsets = (long *)xmalloc((num_chunks + 1) * sizeof(long));

    chunk_offsets[0] = 0;
    for (long i = 0; i < num_boundaries; i++) {
        chunk_offsets[i + 1] = boundaries[i];
    }
    chunk_offsets[num_chunks] = len;

    /* Step 3: Parallel BLAKE3 hashing (release GVL for true C-level parallelism) */
    char *hash_buf = (char *)xmalloc(num_chunks * BLAKE3_HASH_LEN);
    const char *key_ptr = RSTRING_PTR(key);

    int num_threads = optimal_thread_count(num_chunks);
    parallel_blake3_ctx pctx = {
        .num_chunks    = num_chunks,
        .source_ptr    = (const char *)bytes,
        .key_ptr       = key_ptr,
        .chunk_offsets = chunk_offsets,
        .hash_ptr      = hash_buf,
        .num_threads   = num_threads
    };
    rb_thread_call_without_gvl(parallel_blake3_without_gvl, &pctx, RUBY_UBF_IO, NULL);

    /* Step 4: Build Ruby objects (under GVL) */
    VALUE ranges = rb_ary_new2(num_chunks);
    VALUE hashes = rb_str_new(hash_buf, num_chunks * BLAKE3_HASH_LEN);

    for (long i = 0; i < num_chunks; i++) {
        rb_ary_push(ranges, rb_ary_new_from_args(2, LONG2NUM(chunk_offsets[i]), LONG2NUM(chunk_offsets[i + 1])));
    }

    /* Clean up */
    xfree(hash_buf);
    xfree(chunk_offsets);
    if (boundaries != stack_boundaries) {
        xfree(boundaries);
    }

    return rb_ary_new_from_args(2, ranges, hashes);
}

/* --------------------------------------------------------------------------
 * Full upload pipeline: CDC + Blake3 (parallel) + Serialize in a single call.
 *
 * Combines content-defined chunking, parallel BLAKE3 keyed hashing (via pthread),
 * and xorb serialization into one function, eliminating all intermediate Ruby
 * object creation between steps. BLAKE3 runs in parallel via pthreads,
 * releasing the GVL for true multi-core utilization.
 *
 * Ruby API: Gearhash.full_pipeline(data, table, key, mask, min_chunk, max_chunk)
 *        -> [String, String, String]
 *           [hashes_concat, ranges_json-like, xorb_data]
 *
 * Returns a 3-element Array:
 *   [0] hashes_concat: concatenated 32-byte BLAKE3 hashes (String)
 *   [1] ranges: Array[[Integer, Integer]] chunk boundaries
 *   [2] xorb_data: serialized xorb binary data (String)
 * -------------------------------------------------------------------------- */
static VALUE rb_gearhash_full_pipeline(
    VALUE self, VALUE data, VALUE table, VALUE key,
    VALUE mask_val, VALUE min_c, VALUE max_c
) {
    (void)self;
    Check_Type(data, T_STRING);
    Check_Type(table, T_ARRAY);

    if (!blake3_ensure_loaded()) {
        rb_raise(rb_eRuntimeError, "blake3 shared library not found");
    }

    const uint8_t *bytes = (const uint8_t *)RSTRING_PTR(data);
    long len = RSTRING_LEN(data);
    uint64_t mask = NUM2ULL(mask_val);
    long min_chunk = NUM2LONG(min_c);
    long max_chunk = NUM2LONG(max_c);

    /* Step 1: Scan boundaries (pure C, no Ruby objects) */
    long stack_boundaries[MAX_BOUNDARY_STACK];
    long *boundaries = stack_boundaries;
    long max_boundaries = len / min_chunk + 1;

    if (max_boundaries > MAX_BOUNDARY_STACK) {
        boundaries = (long *)xmalloc(max_boundaries * sizeof(long));
    }

    uint64_t tbl[256];
    get_cached_table(tbl, table);
    long num_boundaries = scan_boundaries(bytes, len, tbl, mask, min_chunk, max_chunk, boundaries);

    long num_chunks = num_boundaries + 1;

    /* Step 2: Build chunk offset array */
    long *chunk_offsets = (long *)xmalloc((num_chunks + 1) * sizeof(long));
    chunk_offsets[0] = 0;
    for (long i = 0; i < num_boundaries; i++) {
        chunk_offsets[i + 1] = boundaries[i];
    }
    chunk_offsets[num_chunks] = len;

    /* Step 3: Parallel BLAKE3 hashing (release GVL) */
    char *hash_buf = (char *)xmalloc(num_chunks * BLAKE3_HASH_LEN);
    const char *key_ptr = RSTRING_PTR(key);

    int num_threads = optimal_thread_count(num_chunks);
    parallel_blake3_ctx pctx = {
        .num_chunks    = num_chunks,
        .source_ptr    = (const char *)bytes,
        .key_ptr       = key_ptr,
        .chunk_offsets = chunk_offsets,
        .hash_ptr      = hash_buf,
        .num_threads   = num_threads
    };
    rb_thread_call_without_gvl(parallel_blake3_without_gvl, &pctx, RUBY_UBF_IO, NULL);

    /* Step 4: Serialize xorb data (under GVL, single allocation) */
    long total_xorb_size = 0;
    for (long i = 0; i < num_chunks; i++) {
        long chunk_len = chunk_offsets[i + 1] - chunk_offsets[i];
        total_xorb_size += 8 + chunk_len; /* header + data */
    }

    VALUE xorb_data = rb_str_new(NULL, total_xorb_size);
    char *xorb_ptr = RSTRING_PTR(xorb_data);
    long xorb_offset = 0;

    for (long i = 0; i < num_chunks; i++) {
        long s = chunk_offsets[i];
        long e = chunk_offsets[i + 1];
        long chunk_len = e - s;

        /* Write xorb header: \x00 + 3-byte LE size + \x00 + 3-byte LE size */
        uint8_t sb[3];
        sb[0] = (uint8_t)(chunk_len & 0xFF);
        sb[1] = (uint8_t)((chunk_len >> 8) & 0xFF);
        sb[2] = (uint8_t)((chunk_len >> 16) & 0xFF);

        xorb_ptr[xorb_offset] = '\x00';
        memcpy(xorb_ptr + xorb_offset + 1, sb, 3);
        xorb_ptr[xorb_offset + 4] = '\x00';
        memcpy(xorb_ptr + xorb_offset + 5, sb, 3);
        xorb_offset += 8;

        /* Copy chunk data from source buffer */
        memcpy(xorb_ptr + xorb_offset, (const char *)bytes + s, chunk_len);
        xorb_offset += chunk_len;
    }

    rb_str_set_len(xorb_data, xorb_offset);

    /* Step 5: Build Ruby objects */
    VALUE ranges = rb_ary_new2(num_chunks);
    for (long i = 0; i < num_chunks; i++) {
        rb_ary_push(ranges, rb_ary_new_from_args(2, LONG2NUM(chunk_offsets[i]), LONG2NUM(chunk_offsets[i + 1])));
    }

    VALUE hashes_concat = rb_str_new(hash_buf, num_chunks * BLAKE3_HASH_LEN);

    /* Clean up */
    xfree(hash_buf);
    xfree(chunk_offsets);
    if (boundaries != stack_boundaries) xfree(boundaries);

    return rb_ary_new_from_args(3, hashes_concat, ranges, xorb_data);
}

/* --------------------------------------------------------------------------
 * Module initialization
 * -------------------------------------------------------------------------- */

void Init_gearhash(void) {
    VALUE mHuggingFaceStorage = rb_define_module("HuggingFaceStorage");
    VALUE mGearhash = rb_define_module_under(mHuggingFaceStorage, "Gearhash");
    rb_define_module_function(mGearhash, "cdc_chunk", rb_gearhash_cdc_chunk, 5);
    rb_define_module_function(mGearhash, "xorb_xor", rb_gearhash_xorb_xor, 2);
    rb_define_module_function(mGearhash, "serialize_xorb_from_ranges", rb_gearhash_serialize_xorb_from_ranges, 2);
    rb_define_module_function(mGearhash, "build_xorb_info", rb_gearhash_build_xorb_info, 4);
    rb_define_module_function(mGearhash, "build_full_shard", rb_gearhash_build_full_shard, 11);
    rb_define_module_function(mGearhash, "blake3_batch_keyed_from_ranges", rb_gearhash_blake3_batch_keyed_from_ranges, 3);
    rb_define_module_function(mGearhash, "cdc_and_hash", rb_gearhash_cdc_and_hash, 6);
    rb_define_module_function(mGearhash, "full_pipeline", rb_gearhash_full_pipeline, 6);

    VALUE cCdcState = rb_define_class_under(mGearhash, "CdcState", rb_cObject);
    rb_define_alloc_func(cCdcState, rb_gearhash_cdc_state_alloc);
    rb_define_method(cCdcState, "initialize", rb_gearhash_cdc_state_init, 4);
    rb_define_method(cCdcState, "feed", rb_gearhash_cdc_state_feed, 1);
    rb_define_method(cCdcState, "finalize", rb_gearhash_cdc_state_finalize, 0);
    rb_undef_method(CLASS_OF(cCdcState), "allocate");
}
