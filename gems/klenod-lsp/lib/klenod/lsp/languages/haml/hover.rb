# frozen_string_literal: true

require "language_server-protocol"

module Klenod
  module LSP
    module Languages
      class Haml
        # Markdown summary of the module a component tag or import literal
        # refers to: its module id, its path, and the props a Haml component
        # reads through the configured `$name` mapping.
        module Hover
          Interface = LanguageServer::Protocol::Interface
          Constant = LanguageServer::Protocol::Constant

          PROP_TOKEN = /\$(?<name>[a-z]\w*|\*)/

          module_function

          def call(target, module_id, workspace)
            path = workspace.path_for_module_id(module_id)
            lines = ["**#{target.name}** · `#{module_id}`"]
            lines << "`#{relative_path(path, workspace.source_dir)}`" if path

            props = props_for(path, workspace)
            lines << "Props: #{props.map { |prop| "`#{prop}`" }.join(", ")}" unless props.empty?

            Interface::Hover.new(
              contents: Interface::MarkupContent.new(kind: Constant::MarkupKind::MARKDOWN, value: lines.join("\n\n")),
              range: target.span.to_range
            )
          end

          def relative_path(path, source_dir)
            path.delete_prefix("#{source_dir}/")
          end

          # Only lowercase `$name` globals are rewritten to prop reads, and only
          # when the Haml plugin maps global variables at all.
          def props_for(path, workspace)
            return [] unless path && File.extname(path) == ".haml"
            return [] unless workspace.haml_variables[:global]

            source = File.read(path)
            source.scan(PROP_TOKEN).flatten.uniq.sort.map { |name| "$#{name}" }
          rescue SystemCallError
            []
          end
        end
      end
    end
  end
end
