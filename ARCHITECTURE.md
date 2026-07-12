# Klenod Architecture

Klenod is a Ruby module bundler. It resolves source-root-relative modules, transforms them through plugins, records a dependency graph, evaluates modules on demand, and can serialize a runtime-only bundle.

The design goal is close to Vite/Rollup/Parcel for graph and plugin behavior, with Ruby-native runtime values and optional NextJS/SvelteKit-inspired routing in a plugin.

## Package Boundaries

`Klenod::Build` owns development/build concerns:

- dependency resolution
- source loading
- plugin transforms
- graph collection
- invalidation
- asset generation
- runtime bundle serialization

`Klenod::Dev` owns watching and update events. It observes source changes and asks the build graph to invalidate and reload affected records.

`Klenod::Runtime` owns production loading:

- `Klenod::Runtime::Bundle`
- `Klenod::Runtime::Mod`
- serialized module specs
- runtime import values
- runtime asset specs

Runtime must not require build plugins or plugin-only dependencies such as RMagick, `image_size`, Haml parsers, or CSS transformers.

Optional integrations, such as HTTP asset serving, live outside the core graph/runtime boundary.

## Module Lifecycle

Klenod separates collection from evaluation.

Collection reads and transforms a module:

1. Resolve an import specifier into a module id.
2. Load source from disk, a virtual module, or a plugin.
3. Transform source through plugins.
4. Record dependencies, assets, source maps, metadata, and watched patterns.
5. Collect eager dependency records.
6. Finalize the module record.

Evaluation runs Ruby code:

1. Instantiate `Klenod::Runtime::Mod` for the collected record.
2. Evaluate transformed Ruby source inside the generated module.
3. Resolve import values for the evaluated module.
4. Expose exports through the module's `Exports` constant.

The public APIs reflect this split:

- `context.collect(...)` collects without evaluating.
- `context.entry(...)` collects an entry and returns a reusable handle.
- `context.evaluate(...)` collects and evaluates immediately.
- `entry.exports`, `entry.call(...)`, and `context.exports(...)` evaluate on demand.

Build mode should collect and serialize modules without evaluating application top-level code.

## Module Identity And Imports

Module ids are source-root-relative by default:

```ruby
import("./Card")
import("/components/Card")
import("virtual:router")
```

Relative imports resolve from the importer. Leading-slash imports resolve from the configured source directory. Virtual modules use explicit schemes, currently `virtual:`.

Future external imports should use schemes such as `plugin:` or `gem:` and be resolved by plugins before filesystem resolution.

`import("...")` creates an eager dependency. `lazy_import("...")` records the dependency but returns a lazy runtime value that loads when called.

Eager cycles are errors. Lazy imports are the intended way to defer cyclic or expensive branches.

## Plugin Pipeline

Plugins can participate in several phases:

- `resolve(dependency, context)`: map a dependency to a module id.
- `load(module_id, context)`: provide source for virtual or custom modules.
- `transform(module_id, code, context)`: rewrite source and emit dependencies/assets/metadata.
- `finalize(module_id, result, resolved_dependencies, dependency_records, context)`: adjust transform output after dependencies are collected.
- `import_value(resolved_dependency, record, context)`: provide development/evaluation import values.
- `runtime_import_value(resolved_dependency, record, context)`: provide serialized bundle import values.

Collection hooks must not depend on evaluated app exports. Runtime import values must be serializable and must not require build-only dependencies.

Sibling dependency loading can overlap. Plugins should avoid unguarded shared mutable state in `load` and `transform`.

## Runtime Modules

Each collected module is evaluated as a `Klenod::Runtime::Mod`.

Runtime modules get stable generated constant names so instances can be marshaled and unmarshaled. Transformed source is evaluated inside the generated runtime module, and exported values live under `Exports`.

Ruby and Haml modules generally assign `Default` for the default export. Importing a Haml file from Haml/Ruby returns the component class.

`__FILE__` is rewritten through runtime source-root handling so bundles can be built in one path and loaded in another. Source maps and backtrace rewriting handle transformed sources such as Haml.

## Assets

Plugins emit assets during collection. Assets use two important identifiers:

- `logical_name`: stable source-root-relative path, without query parameters.
- `output_path`: public content-hashed browser path.

Example:

```ruby
logical_name # "images/hero.png"
output_path  # "/assets/hero.640w.abcd1234.png"
```

Import query parameters configure the import without changing the logical name:

```ruby
import("images/hero.png?width=320,640")
import("images/hero.png?width=640")
```

Generated variants should dedupe overlapping work.

Build assets can hold or generate bytes. Runtime asset specs keep metadata only. Development servers/frameworks can serve assets from `context.asset(path).bytes` or `context.asset_bytes(path, assets_dir:)`.

`assets_for_module(...)` and `asset_references_for_module(...)` accept a module id or an array of route roots. This allows route-scoped CSS inclusion instead of including every graph stylesheet on every page.

`asset_references_for_module(...)` attaches a graph traversal `index` to each returned asset. The example web app writes this as `data-index` on stylesheet links.

## CSS

The CSS plugin transforms CSS through `mayu-css` and emits browser stylesheet assets.

Import behavior depends on the importer:

- CSS importing CSS receives the transformed stylesheet path.
- Ruby or Haml importing CSS receives a class-name map.

Scoped CSS maps:

- Class selectors use normal symbol keys, e.g. `:button`.
- Tag selectors use `__`-prefixed symbol keys, e.g. `:__figure`.

The Haml transformer can automatically apply scoped tag classes and explicit Haml classes. Class joining should be centralized in a `clsx`-style helper.

CSS order is derived from route-scoped graph traversal. Root/layout CSS should come before page and component CSS.

## Haml

The Haml plugin is an adapter, not a renderer.

The framework supplies:

- a component base class, e.g. `Example::Component`
- a factory module, e.g. `Example::H`

The plugin transforms `.haml` into Ruby that defines a component class and exports it as `Default`.

Companion dependencies:

- `Component.haml` automatically imports `Component.css` as `Styles` when present.
- It watches `Component.intl.*.toml` and exposes translations.
- Companion add/update/remove invalidates the owning Haml module.

Source maps are represented with `SourceMapMark` comments in generated Ruby. Backtrace rewriting maps runtime exceptions back to original Haml source lines. Parse errors should show source context directly.

Haml semantics:

- `=` prints.
- `-` is silent.
- Silent blocks must evaluate to `nil`.
- Printed blocks such as `= if ...` should render their body.
- Object references like `%div[@user, :greeting]` are treated as a key-style prop rather than HTML id/class generation.

The factory API currently expects:

```ruby
def self.[](tag, *children, **props)
end
```

## Router Plugin

Routing is optional and plugin-owned. Core Klenod should not assume web routing.

`RouterPlugin` discovers routes under a configured pages directory and generates `virtual:router`.

Supported route files:

- `page.rb`
- `page.haml`
- `route.rb`
- `layout.rb`
- `layout.haml`

Supported segment forms:

- `[id]`
- `[...slug]`
- `[[...slug]]`
- `(group)`
- `@slot`
- `(.)photo`
- `(..)profile`
- `(...)login`

Generated router matches expose:

- `match.page`
- `match.handler`
- `match.layouts`
- `match.slots`
- `match.params`
- `match.route`

A directory can contain both a page and `route.rb`. The router exposes both; the framework decides which one to use for a request.

The example server follows SvelteKit-style dispatch:

- `PUT`, `PATCH`, `DELETE`, and `OPTIONS` always use `route.rb`.
- `GET`, `POST`, and `HEAD` render the page when `Accept` prefers `text/html`.
- Other `GET`, `POST`, and `HEAD` requests use `route.rb`.
- Hybrid `GET` handler responses include `Vary: Accept`.

The router should stay request-agnostic. Request dispatch belongs in the framework/server layer.

## Development Updates

`Klenod::Dev::Watcher` watches source files and asks the build graph to invalidate affected modules.

Invalidation considers:

- changed module source files
- removed module files
- changed dependencies
- watched patterns such as Haml companion CSS and intl files
- virtual modules such as `virtual:router`

Collected-but-not-evaluated modules should remain unevaluated after invalidation. `apply_update` should not force entry evaluation unless the entry was already evaluated or the caller explicitly asks for exports/calls.

Frameworks can subscribe to updates:

```ruby
context.on_update do |event|
  update = context.apply_update(event, entry: entry, assets_dir: "public")
end
```

## Build And Bundle

Build mode collects entrypoints and runtime dependencies, writes emitted assets when requested, and serializes runtime module specs with `Marshal.dump`.

Runtime bundles contain:

- entrypoint mapping
- module specs
- import specs and runtime import values
- asset specs
- source-root metadata

Runtime loading evaluates modules lazily. A bundle can also be written as an executable Ruby file with a small Ruby prelude and binary marshal data after `__END__`.

## Example Framework Boundary

`example/web` is a reference consumer, not Klenod core.

It demonstrates:

- `async-http` serving
- request/response objects
- encrypted cookie sessions with `rbnacl`
- CSRF helpers
- route handler dispatch
- layouts and slots
- Haml factory rendering
- asset serving from the build context

Framework-specific concerns should usually stay there or in a separate integration layer, not in `Klenod::Build` or `Klenod::Runtime`.

## Open Design Areas

The main areas still evolving:

- External import schemes such as `plugin:` and `gem:`.
- More precise route visualization and route ordering tools.
- Async rendering and context propagation beyond `Thread.current`.
- A future `klenod dev` command or TUI, if it can remain framework-neutral.
- Splitting build/dev/runtime into separate gems after the boundaries settle.
