# frozen_string_literal: true

require "mkmf"

extension_name = "hugging_face_storage/gearhash"
dir_config(extension_name)
create_makefile(extension_name)
