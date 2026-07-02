# frozen_string_literal: true

require_relative "../plugin"
require_relative "../dependency"
require_relative "../module_id"
require_relative "../transform_result"
require_relative "../watched_pattern"

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        def transform(module_id, _code, context)
          return super unless module_id.extname == ".haml"

          companion_css = companion_path(module_id, ".css")
          dependencies = []
          styles_source = "{}.freeze"

          if context.absolute_path(companion_css).file?
            dependency =
              Dependency
                .create(
                  specifier: "./#{File.basename(companion_css.path)}",
                  importer_id: module_id,
                  kind: :companion_style,
                  metadata: {optional: true}
                )
                .with(id: "#{module_id}:companion_style")
            dependencies << dependency
            styles_source = "__klenod_import__(#{dependency.id.inspect})"
          end

          TransformResult.new(
            <<~RUBY,
              Styles = #{styles_source}
              Translations = {}.freeze
            RUBY
            dependencies,
            nil,
            [],
            companion_patterns(module_id),
            {}
          )
        end

        private

        def companion_patterns(module_id)
          base = module_id.path.delete_suffix(".haml")

          [
            WatchedPattern.new(module_id, "#{base}.css", :companion_style, {}),
            WatchedPattern.new(module_id, "#{base}.intl.*.toml", :companion_intl, {})
          ]
        end

        def companion_path(module_id, extname)
          ModuleId.new(module_id.path.delete_suffix(".haml") + extname, nil)
        end
      end
    end
  end
end
