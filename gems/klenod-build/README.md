# klenod-build

`klenod-build` builds [Klenod](https://github.com/aalin/klenod) bundles.

It owns development and build-time behavior:

- module resolving and graph collection
- plugins
- asset generation
- bundle serialization
- a basic `klenod` CLI
- file watching and updates in development mode

Use this gem when building an application, running development tooling, or authoring build plugins.

```ruby
require "klenod/build"

context = Klenod::Build::Context.new(source_dir: "src")
context.build(entrypoints: ["pages/server"], output: "dist/klenod.bundle")
```

Then you can load that bundle with [klenod-runtime](https://github.com/aalin/klenod/tree/main/gems/klenod-runtime).

The CLI can also generate a [Graphviz](https://graphviz.org/) DOT-file from a generated bundle:

```sh
bundle exec klenod graph dist/klenod.bundle > graph.dot
```

Klenod's internal virtual modules are hidden by default. Pass
`--internal-virtual-modules` to include them in the graph.
