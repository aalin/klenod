# frozen_string_literal: true

module Klenod
  class Error < StandardError; end unless const_defined?(:Error, false)

  module Build
    class Error < Klenod::Error; end
    class ResolveError < Error; end
    class DynamicImportError < Error; end
    class UnsupportedFileError < Error; end
  end
end
