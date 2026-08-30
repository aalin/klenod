# Haml Plugin Internals

The public plugin entry point is `../haml.rb`, constructed with
`Klenod::Build::Plugins::HamlPlugin.new`. Related classes live under the same
`Klenod::Build::Plugins::HamlPlugin` namespace.
Keep the entry point focused on plugin hooks and graph integration.

Internal responsibilities are split by phase:

- `errors.rb`: parse error wrappers and Haml transform result values.
- `parser.rb`: Haml parser adapter and metadata added to Haml parse nodes.
- `transformer.rb`: conversion from parsed Haml nodes into generated Ruby.
- `transformer/ruby_builder.rb`: SyntaxTree-backed Ruby AST/source helpers.
- `helper_source.rb`: generated `virtual:klenod/haml_helper` source.
- `companions.rb`: companion CSS/intl path and invalidation helpers.

The Haml plugin should stay framework-neutral. It generates component classes
and calls the configured factory, but rendering semantics belong to the
framework using Klenod.
