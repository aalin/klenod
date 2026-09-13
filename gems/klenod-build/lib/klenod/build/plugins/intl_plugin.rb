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

          CachedTranslations = Data.define(:mtime, :size, :translations)

          def initialize
            @cache = {}
          end

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

          # Changed or removed companions leave the cache immediately, so it
          # only ever holds live files. Nothing else needs invalidating: the
          # owning Haml module is re-transformed by HamlPlugin's own hook.
          def invalidate_module_ids(paths, _context)
            paths.each { |path| @cache.delete(File.expand_path(path)) }
            []
          end

          private

          # Parsed translations are kept per file and validated by stat, so a
          # module that transforms often, as in the language server, does not
          # re-read and re-parse companions that did not change. Read the file
          # here rather than using TomlRB.load_file, so a parse failure can
          # carry the source for the excerpt.
          def translations_from(path, module_id)
            stat = File.stat(path)
            cached = @cache[path]
            return cached.translations if cached && cached.mtime == stat.mtime && cached.size == stat.size

            source = File.read(path)
            translations =
              begin
                TomlRB.parse(source)
              rescue TomlRB::Error => error
                raise ParseError.new(error, source: source, module_id: companion_id(path, module_id))
              end

            @cache[path] = CachedTranslations.new(stat.mtime, stat.size, translations)
            translations
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
