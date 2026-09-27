# frozen_string_literal: true

require_relative "build/version"
require "klenod/runtime"
require_relative "build/context"
require_relative "build/exception_formatter"
require_relative "build/resolution_error_formatter"

module Klenod
  class Error < StandardError; end unless const_defined?(:Error, false)

  module Build
    autoload :Graphviz, "klenod/build/graphviz"
    autoload :UpdateEvent, "klenod/build/watcher"
    autoload :Watcher, "klenod/build/watcher"
  end
end
