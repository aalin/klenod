# frozen_string_literal: true

%w[
  ../gems/klenod/lib
  ../gems/klenod-runtime/lib
  ../gems/klenod-build/lib
  ../gems/klenod-rack/lib
].reverse_each { $LOAD_PATH.unshift File.expand_path(it, __dir__) }
require "klenod"

require "minitest/autorun"
