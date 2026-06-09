# frozen_string_literal: true

module HuggingFaceStorage
  # Builds shard binary metadata for Xet storage.
  # @api private
  # :nodoc:
  module XetShardBuilder
    SHARD_TAG = [72, 70, 82, 101, 112, 111, 77, 101, 116, 97, 68, 97, 116, 97, 0, 85,
                 105, 103, 69, 106, 123, 129, 87, 131, 165, 189, 217, 92, 205, 209, 74, 169].pack("C*")

    UINT32_SIZE = 4
    UINT64_SIZE = 8
    SHARD_HEADER_SIZE = 48
    SHARD_FOOTER_SIZE = 200
    BOOKEND_SIZE = 48
    HASH_LEN = 32
    MDB_FILE_FLAG_WITH_VERIFICATION = 0x80000000
    MDB_FILE_FLAG_WITH_METADATA_EXT = 0x40000000

    # Pre-computed frozen zero buffers to avoid per-call allocations.
    ZERO_8B = ("\x00" * 8).b.freeze
    ZERO_16B = ("\x00" * 16).b.freeze
    ZERO_32B = ("\x00" * 32).b.freeze
    ZERO_48B = ("\x00" * 48).b.freeze
    # Pre-computed bookend: 32-byte \xFF hash + 16-byte zero padding
    BOOKEND = (("\xFF" * 32) + ("\x00" * 16)).b.freeze

    def build_shard(file_hash:, representation:, chunk_hashes:, chunk_lengths:, xorb_hash:, xorb_serialized_size:,
                    sha256:)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:build_full_shard)
        rep_xorb_hashes = representation.map { |r| r[:xorb_hash] }
        rep_lengths = representation.map { |r| r[:length] }
        rep_index_starts = representation.map { |r| r[:index_start] }
        rep_index_ends = representation.map { |r| r[:index_end] }
        rep_range_hashes = representation.map { |r| r[:range_hash] }
        return HuggingFaceStorage::Gearhash.build_full_shard(
          file_hash, sha256,
          rep_xorb_hashes, rep_lengths, rep_index_starts, rep_index_ends, rep_range_hashes,
          xorb_hash, chunk_hashes, chunk_lengths, xorb_serialized_size
        )
      end

      file_info = build_file_info_section(file_hash, representation, sha256)
      total_raw = chunk_lengths.sum
      xorb_info = build_xorb_info_section_single(xorb_hash, chunk_hashes, chunk_lengths,
                                                 xorb_serialized_size, total_raw)
      assemble_shard(file_info, xorb_info, xorb_serialized_size, total_raw)
    end

    def build_multi_file_shard(file_metas, xorbs)
      file_info = "".b
      xorb_info = "".b
      total_disk = 0

      file_metas.each do |fm|
        rep = fm[:representation]
        file_info << build_file_info_section(fm[:file_hash], rep, fm[:sha256])
      end

      total_raw = 0

      xorbs.each do |xorb|
        xorb_raw = xorb[:chunks].sum { |c| c[:length] }
        total_raw += xorb_raw
        serialized_size = xorb[:serialized_size] || xorb[:data]&.bytesize || 0
        total_disk += serialized_size
        build_xorb_info_section_for_xorb(xorb_info, xorb, xorb_raw, serialized_size)
      end

      assemble_shard(file_info, xorb_info, total_disk, total_raw)
    end

    def build_representation(chunk_start, chunk_count, all_chunks, xorbs)
      return [] if chunk_count.zero?

      chunk_map = build_xorb_refs(xorbs)
      ranges = build_ranges(chunk_start, chunk_count, all_chunks, chunk_map)

      ranges.map do |xorb_idx, idx_start, idx_end, length, hashes|
        {
          xorb_hash: xorbs[xorb_idx][:hash],
          index_start: idx_start,
          index_end: idx_end,
          length: length,
          range_hash: @hasher.compute_verification_hash(hashes),
        }
      end
    end

    private

    def build_file_info_section(file_hash, representation, sha256)
      buf = String.new(capacity: file_info_capacity(representation), encoding: Encoding::BINARY)

      buf << pack_file_header(file_hash, representation.length)
      buf << pack_chunk_entries(representation)
      buf << sha256.b
      buf << ZERO_16B

      buf
    end

    def file_info_capacity(representation)
      rep_entry_size = HASH_LEN + UINT32_SIZE + UINT32_SIZE + UINT32_SIZE + UINT32_SIZE
      range_hash_size = HASH_LEN + UINT64_SIZE + UINT64_SIZE
      HASH_LEN + UINT32_SIZE + UINT32_SIZE + UINT64_SIZE +
        (representation.length * rep_entry_size) +
        (representation.length * range_hash_size) + HASH_LEN + UINT64_SIZE + UINT64_SIZE
    end

    def build_xorb_info_section_single(xorb_hash, chunk_hashes, chunk_lengths, xorb_serialized_size, total_raw)
      # Use C extension when available (zero per-chunk Ruby allocations)
      if defined?(HuggingFaceStorage::Gearhash) && HuggingFaceStorage::Gearhash.respond_to?(:build_xorb_info)
        return HuggingFaceStorage::Gearhash.build_xorb_info(xorb_hash, chunk_hashes, chunk_lengths,
                                                            xorb_serialized_size)
      end

      # Ruby fallback
      chunk_entry_size = HASH_LEN + UINT32_SIZE + UINT32_SIZE + UINT64_SIZE
      buf = String.new(capacity: xorb_info_capacity(chunk_hashes.length, chunk_entry_size), encoding: Encoding::BINARY)

      buf << xorb_hash.b
      buf << [0, chunk_hashes.length, total_raw, xorb_serialized_size].pack("VVVV")

      offset = 0
      chunk_hashes.each_with_index do |ch, i|
        buf << ch.b
        buf << [offset, chunk_lengths[i]].pack("VV")
        buf << ZERO_8B
        offset += chunk_lengths[i]
      end

      buf
    end

    def xorb_info_capacity(chunk_count, chunk_entry_size)
      HASH_LEN + UINT64_SIZE + UINT64_SIZE + (chunk_count * chunk_entry_size)
    end

    def build_xorb_info_section_for_xorb(buf, xorb, total_raw, serialized_size = nil)
      serialized_size ||= xorb[:serialized_size] || xorb[:data].bytesize
      buf << xorb[:hash].b
      buf << [0, xorb[:chunks].length, total_raw, serialized_size].pack("VVVV")

      offset = 0
      xorb[:chunks].each do |c|
        buf << c[:hash].b
        buf << [offset, c[:length]].pack("VV")
        buf << ZERO_8B
        offset += c[:length]
      end
    end

    def assemble_shard(file_info, xorb_info, xorb_serialized_size, total_raw)
      offsets = compute_shard_offsets(file_info, xorb_info)
      buf = String.new(capacity: offsets[:total_size], encoding: Encoding::BINARY)

      buf << SHARD_TAG.b
      buf << [2, SHARD_FOOTER_SIZE].pack("Q<Q<")
      buf << file_info
      buf << BOOKEND
      buf << xorb_info
      buf << BOOKEND
      buf << [1, offsets[:file_info_offset], offsets[:xorb_info_offset]].pack("Q<Q<Q<")
      buf << ZERO_48B
      buf << ZERO_32B
      buf << [Time.now.to_i, 0].pack("Q<Q<")
      buf << ZERO_48B
      buf << [xorb_serialized_size, total_raw, total_raw, offsets[:footer_offset]].pack("Q<Q<Q<Q<")

      buf
    end

    def compute_shard_offsets(file_info, xorb_info)
      file_info_offset = SHARD_HEADER_SIZE
      xorb_info_offset = file_info_offset + file_info.bytesize + BOOKEND_SIZE
      footer_offset = xorb_info_offset + xorb_info.bytesize + BOOKEND_SIZE
      total_size = SHARD_HEADER_SIZE + file_info.bytesize + BOOKEND_SIZE +
                   xorb_info.bytesize + BOOKEND_SIZE + SHARD_FOOTER_SIZE
      { file_info_offset: file_info_offset, xorb_info_offset: xorb_info_offset,
        footer_offset: footer_offset, total_size: total_size }
    end

    def build_xorb_refs(xorbs)
      chunk_map = [] # : Array[[Integer, Integer]]
      xorbs.each_with_index do |xorb, xi|
        xorb[:chunks].each_index do |ci|
          chunk_map << [xi, ci]
        end
      end
      chunk_map
    end

    def build_ranges(chunk_start, chunk_count, all_chunks, chunk_map)
      # @type var ranges: Array[[Integer, Integer, Integer, Integer, Array[String]]]
      ranges = []
      (chunk_start...(chunk_start + chunk_count)).each do |gi|
        xorb_idx, chunk_idx = chunk_map[gi]
        chunk = all_chunks[gi]

        if ranges.empty? || ranges.last[0] != xorb_idx ||
           ranges.last[2] != chunk_idx
          ranges << [xorb_idx, chunk_idx, chunk_idx + 1, chunk[:length], [chunk[:hash]]]
        else
          ranges.last[2] += 1
          ranges.last[3] += chunk[:length]
          ranges.last[4] << chunk[:hash]
        end
      end
      ranges
    end

    def pack_file_header(file_hash, representation_size)
      file_flags = MDB_FILE_FLAG_WITH_VERIFICATION | MDB_FILE_FLAG_WITH_METADATA_EXT
      buf = "".b
      buf << file_hash.b
      buf << [file_flags, representation_size].pack("VV")
      buf << ZERO_8B
      buf
    end

    def pack_chunk_entries(representation)
      return +"" if representation.empty?

      binary_hashes, packed_uint32s = prepack_chunk_entry_data(representation)
      entry_size = HASH_LEN + (UINT32_SIZE * 4) + HASH_LEN + (UINT64_SIZE * 2)
      buf = String.new(capacity: entry_size * representation.length, encoding: Encoding::BINARY)
      representation.each_with_index do |_, i|
        write_chunk_entry(buf, binary_hashes, packed_uint32s, i)
      end
      buf
    end

    def prepack_chunk_entry_data(representation)
      binary_hashes = representation.flat_map { |rep| [rep[:xorb_hash].b, rep[:range_hash].b] }
      uint32s = representation.flat_map { |rep| [0, rep[:length], rep[:index_start], rep[:index_end]] }
      [binary_hashes, uint32s.pack("V*")]
    end

    def write_chunk_entry(buf, binary_hashes, packed_uint32s, idx)
      buf << binary_hashes[idx * 2]
      buf << packed_uint32s.byteslice(idx * UINT32_SIZE * 4, UINT32_SIZE * 4)
      buf << binary_hashes[(idx * 2) + 1]
      buf << ZERO_16B
    end
  end
end
