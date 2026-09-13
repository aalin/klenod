# frozen_string_literal: true

require_relative "../text"

module Klenod
  module LSP
    module Languages
      # How a language spells references to other modules. Each syntax finds
      # the literals on a line, knows the dependency kind Klenod resolves them
      # with, and recognizes a literal still being typed for completion.
      module Syntax
        Literal = Data.define(:specifier, :span, :kind)

        module Ruby
          IMPORT_CALL = /\b(?<call>(?:lazy_)?import(?:_glob)?)\(\s*(?<quote>["'])(?<specifier>[^"']*)\k<quote>/
          IMPORT_PREFIX = /\b(?:lazy_)?import(?:_glob)?\(\s*["'](?<partial>[^"']*)\z/

          module_function

          # Glob imports name many modules and are skipped.
          def each_literal(line_text, line_index)
            Text.each_match(line_text, line_index, IMPORT_CALL, group: :specifier) do |match, span|
              next if match[:call] == "import_glob"

              yield Literal.new(match[:specifier], span, :haml_import)
            end
          end

          def prefix_partial(prefix)
            IMPORT_PREFIX.match(prefix)&.[](:partial)
          end
        end

        module CSS
          IMPORT = /@import\s+(?:url\(\s*)?(?<quote>["']?)(?<specifier>[^"'()\s;]+)\k<quote>\s*\)?/
          URL = /\burl\(\s*(?<quote>["']?)(?<specifier>[^"'()]+)\k<quote>\s*\)/
          COMPOSES = /\bfrom\s+(?<quote>["'])(?<specifier>[^"']+)\k<quote>/
          IMPORT_PREFIX = /(?:@import\s+(?:url\(\s*)?|\burl\(\s*|\bfrom\s+)(?<quote>["']?)(?<partial>[^"'()\s;]*)\z/
          SKIPPED = /\A(?:data:|#|\z)/

          module_function

          # `@import` first, so the `url()` inside one is not counted twice.
          def each_literal(line_text, line_index)
            covered = []
            [[IMPORT, :css_import], [URL, :asset_url], [COMPOSES, :css_compose]].each do |pattern, kind|
              Text.each_match(line_text, line_index, pattern, group: :specifier) do |match, span|
                next if match[:specifier].match?(SKIPPED)
                next if covered.any? { |range| range.cover?(span.start_character) }

                covered << (match.begin(0)...match.end(0))
                yield Literal.new(match[:specifier], span, kind)
              end
            end
          end

          def prefix_partial(prefix)
            IMPORT_PREFIX.match(prefix)&.[](:partial)
          end
        end
      end
    end
  end
end
