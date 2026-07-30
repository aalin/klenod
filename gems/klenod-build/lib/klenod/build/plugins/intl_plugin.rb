# frozen_string_literal: true

require "toml-rb"

require_relative "../plugin"

module Klenod
  module Build
    module Plugins
      module IntlPlugin
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
                [locale, TomlRB.load_file(path)]
              end
          end
        end
      end
    end
  end
end
