#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"] ||= "1"
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"
require "klenod/test"

require_relative "../lib/framework"
require_relative "../lib/testing/test_runner"

config = Klenod::Test::ConfigLoader.load(File.expand_path("../klenod.test.rb", __dir__))
context = config.context.call
plugin = context.graph.plugins.find { it.is_a?(Klenod::Test::Plugin) }
raise "The example context must include Klenod::Test::Plugin" unless plugin

test_paths = Klenod::Test::Suite.new(context:, plugin:).collect.test_paths
runner = Klenod::Test::CoverageRunner.new(context:, plugin:, config: config.coverage)

exit runner.call { config.execute.call(context, test_paths) }
