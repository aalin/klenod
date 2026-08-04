# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require_relative "gem_import_plugin"
require_relative "ruby_plugin"

module Klenod
  module Build
    module Plugins
      module GemImportPlugin
        class Test < Minitest::Test
          FakeGemSpec = Data.define(:full_gem_path)

          def test_imports_code_from_gem_import_root
            with_fake_gem("klenod-ui") do |dir|
              FileUtils.mkdir_p("#{dir}/klenod/components")
              File.write("#{dir}/klenod/components/Button.rb", <<~RUBY)
                Tokens = import("/tokens")
                Icon = import("./Icon")

                VALUE = [Tokens::VALUE, Icon::VALUE]
              RUBY
              File.write("#{dir}/klenod/components/Icon.rb", "VALUE = :icon\n")
              File.write("#{dir}/klenod/tokens.rb", "VALUE = :tokens\n")

              context = context_for(source_dir: dir)
              record = context.evaluate("gem://klenod-ui/components/Button")

              assert_equal("gem://klenod-ui/components/Button.rb", record.id.to_s)
              assert_equal([:tokens, :icon], context.exports(record)::VALUE)
              assert_equal(
                [
                  "gem://klenod-ui/components/Button.rb",
                  "gem://klenod-ui/components/Icon.rb",
                  "gem://klenod-ui/tokens.rb"
                ],
                context.graph.records.keys.map(&:to_s).sort
              )
            end
          end

          def test_gem_code_can_import_app_code_explicitly
            with_fake_gem("klenod-ui") do |dir|
              FileUtils.mkdir_p("#{dir}/app")
              FileUtils.mkdir_p("#{dir}/klenod")
              File.write("#{dir}/app/local.rb", "VALUE = :app\n")
              File.write("#{dir}/klenod/entry.rb", "Local = import(\"app:/local\")\nVALUE = Local::VALUE\n")

              context = context_for(source_dir: "#{dir}/app")
              record = context.evaluate("gem://klenod-ui/entry")

              assert_equal(:app, context.exports(record)::VALUE)
              assert_includes(context.graph.records.keys.map(&:to_s), "app:/local.rb")
            end
          end

          def test_rejects_paths_that_escape_gem_import_root
            with_fake_gem("klenod-ui") do |dir|
              FileUtils.mkdir_p("#{dir}/klenod")
              File.write("#{dir}/secret.rb", "VALUE = :secret\n")

              context = context_for(source_dir: dir)
              error = assert_raises(Klenod::Build::ResolveError) do
                context.evaluate("gem://klenod-ui/../secret.rb")
              end

              assert_includes(error.message, "escapes import root")
            end
          end

          def test_reports_missing_gem
            context = context_for(source_dir: Dir.pwd)

            error = assert_raises(Klenod::Build::ResolveError) do
              context.evaluate("gem://missing-klenod-test-gem/entry")
            end

            assert_includes(error.message, "Could not find gem")
          end

          private

          def context_for(source_dir:)
            Klenod::Build::Context.new(
              source_dir: source_dir,
              plugins: [
                Plugin.new,
                RubyPlugin::Plugin.new
              ]
            )
          end

          def with_fake_gem(name)
            Dir.mktmpdir do |dir|
              Gem::Specification.singleton_class.class_eval do
                alias_method :__klenod_original_find_by_name, :find_by_name
                remove_method :find_by_name
                define_method(:find_by_name) do |requested_name, *requirements|
                  return FakeGemSpec.new(dir) if requested_name == name

                  __klenod_original_find_by_name(requested_name, *requirements)
                end
              end

              yield dir
            ensure
              Gem::Specification.singleton_class.class_eval do
                remove_method :find_by_name
                alias_method :find_by_name, :__klenod_original_find_by_name
                remove_method :__klenod_original_find_by_name
              end
            end
          end
        end
      end
    end
  end
end
