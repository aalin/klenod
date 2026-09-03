# frozen_string_literal: true

require "klenod/version"

module Klenod
  class Error < StandardError; end
end

require "klenod/runtime"
require "klenod/build"
require "klenod/build/watcher"
require "klenod/test"
