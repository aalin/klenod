# frozen_string_literal: true

require_relative "../plugin"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module RubyPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < Klenod::Build::Plugin
          def transform(module_id, code, context)
            return TransformResult.identity(code) unless module_id.extname == ".rb"

            result =
              RubyImportRewriter
                .new(
                  module_id: module_id,
                  kind: :ruby_import,
                  source_dir: context.source_dir,
                  profiler: context.profiler
                )
                .rewrite(code)
            TransformResult.new(result.code, result.dependencies, nil, [], result.watched_patterns, {})
          end
        end
      end
    end
  end
end
