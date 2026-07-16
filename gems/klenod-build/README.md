# klenod-build

`klenod-build` constructs Klenod module graphs and writes runtime bundles.

It owns development and build-time behavior:

- module resolving and graph collection
- plugin hooks and default plugins
- asset generation
- bundle serialization
- the `klenod` CLI implementation
- development file watching and update events

Use this gem when building an application, running development tooling, or authoring build plugins.

```ruby
require "klenod/build"

context = Klenod::Build::Context.new(source_dir: "src")
context.build(entrypoints: ["pages/server"], output: "dist/klenod.bundle")
```

The CLI can also export a built bundle as Graphviz DOT without evaluating bundled modules:

```sh
bundle exec klenod graph dist/klenod.bundle > graph.dot
```
