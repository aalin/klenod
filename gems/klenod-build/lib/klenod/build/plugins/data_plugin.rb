# frozen_string_literal: true

require "json"
require "toml-rb"
require "yaml"

require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class DataPlugin < Plugin
        def self.extensions(*values)
          const_set(:EXTENSIONS, values.freeze)
        end

        def transform(module_id, code, _context)
          return super unless self.class::EXTENSIONS.include?(module_id.extname)

          data = parse(code)
          TransformResult.new(module_source(data), [], nil, [], [], {data: data})
        end

        def import_value(_resolved_dependency, record, context)
          return nil unless self.class::EXTENSIONS.include?(record.id.extname)

          context.mods.fetch(record.id).const_get(:Exports)::Default
        end

        def runtime_import_value(_resolved_dependency, record, _context)
          return nil unless self.class::EXTENSIONS.include?(record.id.extname)

          record.metadata.fetch(:data)
        end

        private

        def module_source(data)
          <<~RUBY
            Default = #{data.inspect}
          RUBY
        end
      end

      class JsonPlugin < DataPlugin
        extensions ".json"

        private

        def parse(code)
          JSON.parse(code)
        end
      end

      class YamlPlugin < DataPlugin
        extensions ".yaml", ".yml"

        private

        def parse(code)
          YAML.safe_load(code, permitted_classes: [Date, Time, Symbol], aliases: true)
        end
      end

      class TomlPlugin < DataPlugin
        extensions ".toml"

        private

        def parse(code)
          TomlRB.parse(code)
        end
      end

      class TextPlugin < DataPlugin
        extensions ".txt", ".text"

        private

        def parse(code)
          code
        end
      end
    end
  end
end
