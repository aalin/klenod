# frozen_string_literal: true

require_relative "source_map"
require_relative "runtime/mod"
require_relative "runtime/bundle"

module Klenod
  module Runtime
    EXECUTABLE_BUNDLE_MARKER = "\n__END__\n".b.freeze

    def self.load_bundle(source, source_root: nil)
      Bundle.load(source, source_root: source_root)
    end

    def self.load_executable_bundle(path, source_root: nil)
      bytes = File.binread(path)
      marker_index = bytes.index(EXECUTABLE_BUNDLE_MARKER)
      raise ArgumentError, "Missing __END__ marker in executable bundle: #{path}" unless marker_index

      payload = bytes.byteslice(marker_index + EXECUTABLE_BUNDLE_MARKER.bytesize, bytes.bytesize)
      bundle = Marshal.load(payload)
      bundle.source_root = source_root if source_root
      bundle
    end
  end
end
