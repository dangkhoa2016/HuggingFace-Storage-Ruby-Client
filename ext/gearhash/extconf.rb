# frozen_string_literal: true

require "mkmf"

extension_name = "hugging_face_storage/gearhash"
dir_config(extension_name)

# Optimize for speed (-O3) instead of size (-Os).
# -fno-fast-math preserves IEEE 754 compliance for hash determinism.
# NDEBUG disables assertions for production.
append_cppflags("-DNDEBUG")
$CFLAGS = $CFLAGS.sub("-Os", "-O3 -fno-fast-math") # rubocop:disable Style/GlobalVars

create_makefile(extension_name)
