# frozen_string_literal: true

require "uri"

module HuggingFaceStorage
  # @api private
  # :nodoc:
  class PageParameterDetector
    def detect(first_uri, next_uri)
      return nil unless first_uri.host == next_uri.host && first_uri.path == next_uri.path

      first_q = parse_query(first_uri.query)
      next_q = parse_query(next_uri.query)
      all_keys = (first_q.keys + next_q.keys).uniq

      find_page_param(all_keys, first_q, next_q)
    end

    private

    def parse_query(query)
      URI.decode_www_form(query || "").group_by(&:first).transform_values { |v| v.map(&:last) }
    end

    def find_page_param(all_keys, first_q, next_q)
      detected = nil
      all_keys.each do |k|
        fv = first_q[k]&.first
        sv = next_q[k]&.first
        next if fv == sv

        return nil if detected

        fi = Integer(fv, exception: false)
        si = Integer(sv, exception: false)
        return nil unless fi && si && si == fi + 1

        detected = [k, fi]
      end

      detected
    end
  end
end
