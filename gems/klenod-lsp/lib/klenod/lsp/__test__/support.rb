# frozen_string_literal: true

require "logger"
require "minitest/autorun"
require "stringio"

require "klenod/build"
require "klenod/lsp"

module Klenod
  module LSP
    module TestSupport
      FIXTURE_APP = File.expand_path("app", __dir__)
      FIXTURE_SOURCE_DIR = File.join(FIXTURE_APP, "src")

      def fixture_context(source_dir: FIXTURE_SOURCE_DIR, variables: {global: "@__props"}, extra_plugins: [])
        Klenod::Build::Context.new(
          source_dir: source_dir,
          analysis: true,
          plugins: [
            *extra_plugins,
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::IntlPlugin.new,
            Klenod::Build::Plugins::HamlPlugin.new(
              component_base_class: "Fixture::Component",
              factory: "Fixture::H",
              variables: variables
            )
          ]
        )
      end

      def fixture_workspace(**)
        Workspace.new(context: fixture_context(**))
      end

      def fixture_index(workspace, *module_ids)
        index = GraphIndex.new(workspace: workspace, logger: Logger.new(StringIO.new))
        Sync { module_ids.each { |module_id| index.ensure_collected(module_id) } }
        index
      end

      def fixture_path(relative)
        File.join(FIXTURE_SOURCE_DIR, relative)
      end

      def fixture_uri(relative)
        "file://#{fixture_path(relative)}"
      end

      def fixture_source(relative)
        File.read(fixture_path(relative))
      end

      def module_id(relative)
        Klenod::Build::ModuleId.new("app:/#{relative}")
      end

      def position(line, character)
        Text::Position.new(line: line, character: character)
      end
    end
  end
end
