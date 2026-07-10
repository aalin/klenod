# frozen_string_literal: true

module Klenod
  module Build
    class Plugin
      def resolve(_dependency, _context)
        nil
      end

      def load(_module_id, _context)
        nil
      end

      def transform(_module_id, code, _context)
        TransformResult.identity(code)
      end

      def finalize(_module_id, result, _resolved_dependencies, _dependency_records, _context)
        result
      end

      def import_value(_resolved_dependency, _record, _context)
        nil
      end

      def runtime_import_value(resolved_dependency, record, context)
        import_value(resolved_dependency, record, context)
      end

      def emit_assets(_record, _context)
        []
      end
    end
  end
end
