# frozen_string_literal: true

require_relative "../plugin"
require_relative "../ruby_import_rewriter"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class RubyPlugin < Plugin
        def transform(module_id, code, _context)
          return TransformResult.identity(code) unless module_id.extname == ".rb"

          result = RubyImportRewriter.new(module_id: module_id, kind: :ruby_import).rewrite(code)
          TransformResult.new(result.code, result.dependencies, nil, [], [], {})
        end
      end
    end
  end
end
