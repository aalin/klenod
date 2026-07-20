# klenod-runtime

`klenod-runtime` loads and evaluates Klenod bundles in production.

It contains only the runtime pieces needed after a bundle has already been built:

- `Klenod::Runtime::Bundle`
- `Klenod::Runtime::Mod`
- lazy import support
- source maps and backtrace rewriting

This gem should stay free of build plugins and heavyweight build-time dependencies such as RMagick, Syntax Tree, Haml, CSS processing, or file watching.

```ruby
require "klenod/runtime"

bundle = Klenod::Runtime.load_bundle("dist/klenod.bundle")
exports = bundle.exports("pages/server")
```

Production servers can explicitly preload bundled modules:

```ruby
bundle.preload_entrypoints
```
