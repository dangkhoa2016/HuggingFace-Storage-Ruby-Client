# frozen_string_literal: true

module HuggingFaceStorage
  # Serializes xorb data and builds shard metadata for Xet storage.
  # Not thread-safe — create one instance per serialization.
  class XetSerializer
    include XetXorbBuilder
    include XetShardBuilder

    def initialize(hasher = nil)
      @hasher = hasher || XetHasher.new
    end

    def stream_representation_builder

      XetStreamRepresentationBuilder.new(@hasher)

    end
  end
end
