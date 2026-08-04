# Klenod

Klenod is an experimental module bundler for Ruby, inspired by JavaScript bundlers.

Klenod reads files from a source directory, applies plugins, records a dependency graph, and writes a runtime bundle. The runtime bundle can run without build plugins.

The project is still early. The core graph, bundle, asset, router, Haml, CSS, and example-app paths are usable.

## Packages

The repository contains four gems:

- `klenod-runtime`: loads bundles, evaluates modules, reads source maps, and rewrites backtraces.
- `klenod-build`: builds graphs, runs plugins, watches files, writes bundles, and provides the CLI.
- `klenod-rack`: provides Rack helpers for serving bundled assets.
- `klenod`: provides a compatibility gem that depends on build and rack.

Production applications that only load a prebuilt bundle usually need `klenod-runtime` only.

## Basic Usage

Create a build context with a source directory:

```ruby
context = Klenod::Build::Context.new(source_dir: "src")
entry = context.entry("pages/server")
page = entry.exports
```

Ruby modules import other modules with literal `import("...")` calls:

```ruby
Shared = import("../shared")
Styles = import("styles/home.css")
Hero = import("./hero.png?width=320,640&format=png")
```

Relative imports resolve from the importing file. Leading-slash imports resolve from the configured source directory.

```ruby
Card = import("./Card")
Layout = import("/layouts/App")
Router = import("virtual:router")
```

Use `lazy_import("...")` to record a dependency and defer loading its value:

```ruby
Details = lazy_import("./details")

def self.render_details
  Details.call::Default.new.render
end
```

Use `import_glob("...")` for a deterministic hash of matched files:

```ruby
Gallery = import_glob("./gallery/*.{jpg,png}?width=320,640&format=webp")
Pages = import_glob("./pages/*.rb", eager: false)
```

The hash keys are the matched import specifiers without query strings.

## Collection And Evaluation

Klenod separates graph collection from module evaluation.

Collection reads source, transforms it, records dependencies, emits assets, and stores a module record. Evaluation instantiates a `Klenod::Runtime::Mod` and runs the module Ruby code.

These APIs collect without evaluating application code:

- `context.entry(...)`
- `context.collect(...)`

These APIs evaluate on demand:

- `entry.exports`
- `entry.call(...)`
- `context.exports(...)`
- `context.evaluate(...)`

Build mode collects and serializes modules. It does not evaluate application top-level code.

Read [Graph And Plugin Phases](docs/graph-and-plugin-phases.md) for the detailed lifecycle.

## Build A Bundle

Use the Ruby API to build a bundle:

```ruby
bundle = context.build(
  entrypoints: ["pages/server"],
  output: "dist/klenod.bundle",
  assets_dir: "public"
)
```

You can also use the CLI from a directory with `klenod.config.rb`:

```sh
bundle exec klenod build
```

The CLI finds the nearest `klenod.config.rb`. Then it changes into that directory before it builds.

A configuration file is Ruby:

```ruby
source_dir "src"
entrypoint "pages/server"
output "dist/klenod.bundle"
assets_dir "public"
mode :development

plugins [
  Klenod::Build::Plugins::RubyPlugin::Plugin.new
]
```

Load a runtime bundle without build plugins:

```ruby
require "klenod/runtime"

bundle = Klenod::Runtime.load_bundle("dist/klenod.bundle")
page = bundle.exports("pages/server")
```

You can inspect a built bundle as Graphviz DOT:

```sh
bundle exec klenod graph dist/klenod.bundle > graph.dot
dot -Tsvg graph.dot > graph.svg
```

## Entry Handles

Frameworks usually keep an entry handle:

```ruby
entry = context.entry("pages/server")
status, headers, body = entry.call(request, context)
page = entry.exports
stylesheets = entry.assets(type: :css)
```

The handle stays valid after development updates. Klenod resolves it through the current graph state when code asks for exports, calls, or assets.

`entry.assets` returns reachable assets by default. Pass `recursive: false` to get only assets that the entry emits directly.

Watch-mode consumers can apply updates and keep the same handle:

```ruby
context.on_update do |event|
  update = context.apply_update(event, entry: entry, assets_dir: "public")

  if update.success?
    status, headers, body = update.entry.call(nil, context)
    css_assets = update.entry.assets(type: :css)
  else
    update.error_messages.each { |message| warn message }
  end
end
```

`apply_update` refreshes the entry and mirrors changed assets when `assets_dir:` is set.

## Assets

Plugins emit assets through `Klenod::Build::Asset`.

Assets have two stable names:

- `logical_name`: the source-root-relative path without import query parameters.
- `output_path`: the public content-hashed path for browsers.

Example:

```ruby
logical_name # "images/hero.png"
output_path  # "/assets/hero.320w.abc123.png"
```

The graph and runtime bundle expose the same lookup shape:

```ruby
context.asset("/assets/home.abc123.css")
context.assets_for("styles/home.css")
context.assets_for_module("pages/server.rb", type: :css)

bundle.asset("/assets/home.abc123.css")
bundle.assets_for("styles/home.css")
bundle.assets_for_module("pages/server.rb", type: :css)
```

Import query parameters configure one import. They do not change the logical name.

```ruby
LargeHero = import("images/hero.png?width=640&format=png")
ResponsiveHero = import("images/hero.png?width=320,640&format=png")
```

Klenod reuses overlapping generated variants across imports. In this example, it generates the `640` variant once.

When `Context#build` receives `assets_dir:`, Klenod writes emitted assets under that directory.

In development, frameworks can serve `context.asset(path).bytes` or `context.asset_bytes(path, assets_dir:)`.

## Plugins

The default build context includes plugins for Ruby, Haml, Markdown, CSS, SVG, images, and data files.

Read [Built-in Build Plugins](gems/klenod-build/lib/klenod/build/plugins/README.md) for the plugin list and plugin configuration.

## Haml And Markdown

The Haml plugin is an adapter. It does not own rendering policy.

Applications configure a component base class and an HTML factory:

```ruby
Klenod::Build::Plugins::HamlPlugin::Plugin.new(
  component_base_class: "Example::Component",
  factory: "Example::H"
)
```

Haml files export a component class as `Default`.

```ruby
Page = import("./+page.haml")
```

Companion files use fixed names:

- `+page.css` imports as `Styles`.
- `+page.intl.*.toml` imports as translations.

Markdown files can import as components when `MarkdownPlugin` uses the same factory:

```ruby
Article = import("./article.md")
```

Haml can also include inline Markdown:

```haml
:markdown
  # Hello

  A paragraph with [a link](/demo).
```

If `src/markdown-components.rb` exists, Markdown rendering uses its `Default` hash for tag-to-component mappings.

## Router Plugin

Routing belongs to the optional `RouterPlugin`.

Add the plugin, then import `virtual:router`:

```ruby
router_plugin = Klenod::Build::Plugins::RouterPlugin::Plugin.new

context = Klenod::Build::Context.new(
  source_dir: "src",
  plugins: [
    Klenod::Build::Plugins::RubyPlugin::Plugin.new,
    router_plugin
  ]
)

router = context.entry("virtual:router").exports::Default
match = router.match("/blog/hello")
```

The router supports:

- `+page.rb` and `+page.haml`
- `+route.rb`
- `+layout.rb` and `+layout.haml`
- `+error.rb` and `+error.haml`
- `+not-found.rb` and `+not-found.haml`
- dynamic and catch-all segments
- route groups
- parallel route slots
- intercepted route segments

A match exposes:

- `match.page`
- `match.handler`
- `match.layouts`
- `match.slots`
- `match.params`
- `match.route`

The router does not decide request policy. A framework decides whether a request renders a page or calls a route handler.

## Examples

The web example is the main integration test and reference application.

Run these commands from `example/web`:

```sh
cd example/web
bin/build
bin/dev
bin/routes
bin/server
```

`bin/dev` starts a development server on `http://localhost:9292`.

The example includes routes for:

- Haml pages and layouts
- CSS modules
- image variants
- TOML data imports
- forms and sessions
- route handlers
- hybrid page and handler routes
- not-found and error rendering
- route metadata

Read [example/web/README.md](example/web/README.md) for the complete example guide.

The standalone example shows non-web bundle use:

```sh
bundle exec ruby example/standalone/example.test.rb
```

## Development

Run the full test suite:

```sh
bundle exec rake
```

Run focused test suites:

```sh
bundle exec rake test:runtime
bundle exec rake test:build
bundle exec rake test:rack
bundle exec rake test:gems
```

Run a single test file:

```sh
bundle exec ruby gems/klenod-build/lib/klenod/build/plugins/router_plugin.test.rb
```

Run Standard on changed Ruby files:

```sh
RUBOCOP_CACHE_ROOT=/private/tmp/rubocop_cache bundle exec standardrb path/to/file.rb
```

## More Documentation

- [Architecture](ARCHITECTURE.md)
- [Graph And Plugin Phases](docs/graph-and-plugin-phases.md)
- [Web Example](example/web/README.md)
- [Plan](PLAN.md)
