# frozen_string_literal: true

require "klenod/version"
require "klenod/runtime"
require_relative "build/context"

module Klenod
  class Error < StandardError; end unless const_defined?(:Error, false)
end
