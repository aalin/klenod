# <img src="./example/web/src/logo.svg" alt="Klenod" width="200" />

Klenod is an experimental module bundler for Ruby, inspired by JavaScript bundlers.

Klenod reads files from a source directory, applies plugins, records a dependency graph, and writes a runtime bundle.
The runtime bundle can run without build plugins.

Klenod was created because I needed a better module system for my web framework [Mayu](https://github.com/mayu-live/framework).

The project is still early in development. Contributions are welcome.

## Packages

The repository contains seven gems:

- [`klenod`](gems/klenod): provides the build and runtime packages together.
- [`klenod-runtime`](gems/klenod-runtime): loads bundles, evaluates modules, reads source maps, and rewrites backtraces.
- [`klenod-build`](gems/klenod-build): builds graphs, runs plugins, watches files, writes bundles, and provides the CLI.
- [`klenod-test`](gems/klenod-test): runs application tests, watches their dependency graph, and reports source-mapped coverage without choosing a test framework.
- [`klenod-rack`](gems/klenod-rack): provides Rack helpers for serving bundled assets.
- [`klenod-plugin-css`](gems/klenod-plugin-css): adds CSS assets and CSS Modules support.
- [`klenod-plugin-javascript`](gems/klenod-plugin-javascript): adds JavaScript and TypeScript assets.

Production applications that only load a prebuilt bundle usually only need `klenod-runtime`.

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
Styles = import("./styles/home.css")
Hero = import("./hero.png?width=320,640&format=png")
```

Relative imports resolve from the importing file. Bare imports like `import("Card")` are also relative. Leading-slash imports resolve from the current scheme root; for normal app files that is the configured source directory.

```ruby
Card = import("./Card")
Layout = import("/layouts/App")
Router = import("virtual:router")
```

Internally, source files use canonical module ids such as `app:/layouts/App.rb`, while virtual modules use ids such as `virtual:/router.rb`. Plugins can own other schemes, for example `gem://some-gem/components/Button.rb`.

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

Collection reads source, transforms it, records dependencies, emits assets, and stores a module record.

Evaluation instantiates a `Klenod::Runtime::Mod` and runs the module Ruby code inside it.

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
base "/assets/"
mode :development

plugins [
  Klenod::Build::Plugins::RubyPlugin.new
]
```

## Test An Application

The `klenod` meta-gem includes `klenod-test`. Add `Klenod::Test::Plugin` to the
application's plugins, then run:

```sh
bundle exec klenod test --run
bundle exec klenod test --watch
bundle exec klenod coverage
```

The command finds the nearest `klenod.test.rb`. This file provides a fresh build
context and the callback that runs selected test modules with Minitest, RSpec, or
another testing library:

```ruby
context do
  path = File.expand_path("klenod.config.rb", __dir__)
  Klenod::Build::ConfigLoader.load(path).context
end

execute do |context, test_paths|
  # Run the selected test modules and return an integer exit status.
end

coverage report: :brief, minimum: 90
```

Tests run once in CI and watch by default otherwise. A changed test or one of its
dependencies reruns only the affected test files in a fresh worker process.
The coverage command runs the full suite once. Use `--report` and `--minimum` to
override the coverage settings for one run.

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

The graph hides Klenod's internal virtual modules by default. Pass
`--internal-virtual-modules` to include them. Application-facing virtual modules,
such as an imported router module, remain visible.

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

Assets have two stable identifiers and a browser URL:

- `logical_name`: the source-root-relative path without import query parameters.
- `output_path`: the canonical content-hashed graph and disk path.
- `url`: the build-time browser URL.

Example:

```ruby
logical_name # "images/hero.png"
output_path  # "/hero.320w.abc123.png"
```

`output_path` is Klenod's root-relative canonical asset key and on-disk path. `assets_dir:` is its filesystem root, so this example is written as `public/hero.320w.abc123.png`. Set `base` to control the browser URL emitted for it. Bases accept origin-relative paths or HTTP(S) URLs and normalize a missing trailing slash:

```ruby
base "/.assets"                    # "/.assets/hero.320w.abc123.png"
base "https://cdn.example.test"     # "https://cdn.example.test/hero.320w.abc123.png"
```

Every emitted asset exposes its build-time browser URL as `asset.url`; use it when an application renders an asset reference itself. Generated CSS, JavaScript, image, SVG, and font references already use the configured base.

The graph and runtime bundle expose the same lookup shape:

```ruby
context.asset("/home.abc123.css")
context.assets_for("styles/home.css")
context.assets_for_module("pages/server.rb", type: :css)

bundle.asset("/home.abc123.css")
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

The default build context includes these plugins:

- [`RubyPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#rubyplugin): collects Ruby imports and prepares them for the runtime.
- [`IntlPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#intlplugin): loads companion translation files for Haml.
- [`HamlPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#hamlplugin): transforms Haml into Ruby component classes.
- [`MarkdownPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#markdownplugin): transforms Markdown into component factory calls.
- [`GemImportPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#gemimportplugin): resolves modules from exposed paths in installed gems.
- [`SvgPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#svgplugin): emits SVG assets and image metadata.
- [`ImagePlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#imageplugin): emits raster images and responsive variants.
- [`JsonPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#dataplugin-and-data-formats): imports JSON data.
- [`YamlPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#dataplugin-and-data-formats): imports YAML data.
- [`TomlPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#dataplugin-and-data-formats): imports TOML data.
- [`TextPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#dataplugin-and-data-formats): imports text files.

The data format plugins use the shared [`DataPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#dataplugin-and-data-formats) base class.

These built-in plugins are optional:

- [`GoogleFontsPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#googlefontsplugin): downloads Google Fonts and emits local assets.
- [`RouterPlugin`](gems/klenod-build/lib/klenod/build/plugins/README.md#routerplugin): generates a virtual router from a route tree.

Testing, CSS, and JavaScript support are separate gems:

- [`Klenod::Test::Plugin`](gems/klenod-test/README.md): discovers test entrypoints and keeps test files out of application imports.
- [`CSSPlugin`](gems/klenod-plugin-css/README.md): scopes CSS Modules and emits CSS assets.
- [`JavaScriptPlugin`](gems/klenod-plugin-javascript/README.md): collects JavaScript dependencies and emits JavaScript assets.

## Examples

The [web example](example/web/README.md) is the main integration test and
reference application.

The [standalone example](example/standalone/README.md) demonstrates non-web
bundle use.

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
- [Releasing](docs/releasing.md)
- [Web Example](example/web/README.md)
