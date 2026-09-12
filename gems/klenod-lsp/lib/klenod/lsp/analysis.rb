# frozen_string_literal: true

module Klenod
  module LSP
    # Everything the server learned from transforming one document's text.
    #
    # `build_error` is the Klenod::Build::Error that stopped the transform, if
    # any. `ruby_errors` are Prism syntax errors in the generated Ruby, and
    # `resolve_errors` are per-dependency ResolveErrors. A document can carry
    # resolved dependencies and errors at the same time.
    Analysis =
      Data.define(:module_id, :source, :transform, :resolved_dependencies, :build_error, :ruby_errors, :resolve_errors) do
        def lines
          source.lines(chomp: true)
        end

        def source_map
          transform&.source_map
        end

        def resolved_module_id_for(specifier)
          resolved = resolved_dependencies.find { |candidate| candidate.dependency.specifier.to_s == specifier }
          resolved&.module_id
        end
      end

    RubyError = Data.define(:message, :generated_line)
  end
end
