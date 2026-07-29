# frozen_string_literal: true

require_relative "../plugin"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module Ruby
        class Plugin < Klenod::Build::Plugin
          def transform(module_id, code, context)
            return TransformResult.identity(code) unless module_id.extname == ".rb"

            profiler = context.respond_to?(:profiler) ? context.profiler : nil
            source_dir = context.source_dir if context.respond_to?(:source_dir)
            result =
              RubyImportRewriter
                .new(
                  module_id: module_id,
                  kind: :ruby_import,
                  source_dir: source_dir,
                  profiler: profiler
                )
                .rewrite(code)
            TransformResult.new(result.code, result.dependencies, nil, [], result.watched_patterns, {})
          end
        end
      end

      RubyPlugin = Ruby::Plugin
    end
  end
end
