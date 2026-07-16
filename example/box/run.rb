#!/usr/bin/env -S RUBY_BOX=1 ruby
# frozen_string_literal: true

unless defined?(Ruby::Box) && Ruby::Box.enabled?
  abort "Ruby::Box is disabled. Run with `RUBY_BOX=1 ruby run.rb`."
end

def measure(label, &)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
ensure
  duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts format("%s duration: %.2f", label, duration)
end

ALPHA_BOX = Ruby::Box.new
BETA_BOX = Ruby::Box.new

require "bundler/setup"
require "klenod/runtime"

EXAMPLE_ROOT = __dir__
DIST_DIR = File.join(EXAMPLE_ROOT, "dist")
ALPHA_BUNDLE = File.join(DIST_DIR, "alpha.bundle")
BETA_BUNDLE = File.join(DIST_DIR, "beta.bundle")

unless File.file?(ALPHA_BUNDLE) && File.file?(BETA_BUNDLE)
  abort "Missing bundles. Run `bundle exec ruby build.rb` first."
end

alpha = measure("loading alpha") { Klenod::Runtime.load_bundle_in_box(ALPHA_BUNDLE, box: ALPHA_BOX) }
beta = measure("loading beta") { Klenod::Runtime.load_bundle_in_box(BETA_BUNDLE, box: BETA_BOX) }

alpha_exports = alpha.exports("main")
beta_exports = beta.exports("main")
alpha_box_id = alpha_exports.describe[/box (\d+)/, 1]
beta_box_id = beta_exports.describe[/box (\d+)/, 1]

puts alpha_exports.describe
puts beta_exports.describe
puts alpha_exports.greet("Box")
puts beta_exports.greet("Box")
puts "Different boxes: #{alpha_box_id != beta_box_id}"
puts "Main runtime leaked alpha module: #{Klenod::Runtime::Generated.const_defined?(Klenod::Runtime::Mod.constant_name_for("main.rb"), false)}"
