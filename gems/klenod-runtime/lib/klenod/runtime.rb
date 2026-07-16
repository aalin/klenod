# frozen_string_literal: true

require_relative "runtime/version"
require_relative "runtime/source_map"
require_relative "runtime/backtrace_rewriter"
require_relative "runtime/mod"
require_relative "runtime/bundle"
require_relative "runtime/bundle_format"

module Klenod
  module Runtime
    EXECUTABLE_BUNDLE_MARKER = "\n__END__\n".b.freeze

    def self.load_bundle(source, source_root: nil)
      Bundle.load(source, source_root: source_root)
    end

    def self.load_bundle_in_box(source, source_root: nil, box: nil)
      unless defined?(Ruby::Box) && Ruby::Box.enabled?
        raise "Ruby::Box is disabled. Set RUBY_BOX=1 environment variable to use Ruby::Box."
      end

      bytes = source.respond_to?(:read) ? source.read : File.binread(source)
      box ||= Ruby::Box.new
      box.require(File.expand_path(__FILE__))
      box::Klenod::Runtime::BundleFormat.load_bytes(bytes, source_root: source_root)
    end

    def self.load_executable_bundle(path, source_root: nil)
      bytes = File.binread(path)
      marker_index = bytes.index(EXECUTABLE_BUNDLE_MARKER)
      raise ArgumentError, "Missing __END__ marker in executable bundle: #{path}" unless marker_index

      payload = bytes.byteslice(marker_index + EXECUTABLE_BUNDLE_MARKER.bytesize, bytes.bytesize)
      BundleFormat.load_bytes(payload, source_root: source_root)
    end
  end
end
