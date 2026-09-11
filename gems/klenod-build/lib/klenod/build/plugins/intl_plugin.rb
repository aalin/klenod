# frozen_string_literal: true

require "toml-rb"

require_relative "../plugin"
require_relative "../source_error"
require_relative "data_plugin"

module Klenod
  module Build
    module Plugins
      module IntlPlugin
        def self.new(...)
          Plugin.new(...)
        end

        # Translations are TOML, so the report is the TOML one. It names the
        # companion file rather than the component that imports it, because that
        # is the file the developer has to fix.
        class ParseError < TomlPlugin::ParseError
          def kind
            "Intl parse error"
          end
        end

        class Plugin < Klenod::Build::Plugin
          INTL_FILE_RE = /\.intl\.(?<locale>[^\/]+)\.toml\z/

          def translations_for(context, module_id)
            base = module_id.path.delete_suffix(module_id.extname)
            pattern = context.absolute_path(ModuleId.new("#{base}.intl.*.toml", nil)).to_s

            Dir
              .glob(pattern)
              .sort
              .to_h do |path|
                locale = File.basename(path).match(INTL_FILE_RE)[:locale]
                [locale, translations_from(path, module_id)]
              end
          end

          private

          # Read the file here rather than using TomlRB.load_file, so a parse
          # failure can carry the source for the excerpt.
          def translations_from(path, module_id)
            source = File.read(path)

            begin
              TomlRB.parse(source)
            rescue TomlRB::Error => error
              raise ParseError.new(error, source: source, module_id: companion_id(path, module_id))
            end
          end

          # The companion is not a module in the graph, but its id resolves to a
          # path for display just the same.
          def companion_id(path, module_id)
            directory = File.dirname(module_id.path)
            ModuleId.new(File.join(directory, File.basename(path)), nil)
          end
        end
      end
    end
  end
end
