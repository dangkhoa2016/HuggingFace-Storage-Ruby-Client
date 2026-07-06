#include "ruby.h"
#include <stdint.h>

static VALUE rb_gearhash_cdc_chunk(VALUE self, VALUE data, VALUE mask_val, VALUE min_c, VALUE max_c, VALUE table) {
    Check_Type(data, T_STRING);
    Check_Type(table, T_ARRAY);

    const uint8_t *bytes = (const uint8_t *)RSTRING_PTR(data);
    long len = RSTRING_LEN(data);
    uint64_t mask = NUM2ULL(mask_val);
    long min_chunk = NUM2LONG(min_c);
    long max_chunk = NUM2LONG(max_c);

    uint64_t tbl[256];
    for (int i = 0; i < 256; i++) {
        tbl[i] = NUM2ULL(rb_ary_entry(table, i));
    }

    VALUE chunks = rb_ary_new();

    if (len <= min_chunk) {
        rb_ary_push(chunks, rb_ary_new_from_args(2, INT2FIX(0), LONG2NUM(len)));
        return chunks;
    }

    uint64_t h = 0;
    long start = 0;

    for (long i = 0; i < len; i++) {
        h = ((h << 1) + tbl[bytes[i]]) & 0xFFFFFFFFFFFFFFFFULL;
        long size = i - start + 1;

        if (size >= min_chunk && (size >= max_chunk || (h & mask) == 0)) {
            rb_ary_push(chunks, rb_ary_new_from_args(2, LONG2NUM(start), LONG2NUM(i + 1)));
            start = i + 1;
            h = 0;
        }
    }

    if (start < len) {
        rb_ary_push(chunks, rb_ary_new_from_args(2, LONG2NUM(start), LONG2NUM(len)));
    }

    return chunks;
}

void Init_gearhash(void) {
    VALUE mHuggingFaceStorage = rb_define_module("HuggingFaceStorage");
    VALUE mGearhash = rb_define_module_under(mHuggingFaceStorage, "Gearhash");
    rb_define_module_function(mGearhash, "cdc_chunk", rb_gearhash_cdc_chunk, 5);
}
