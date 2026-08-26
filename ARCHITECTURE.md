# Klenod Architecture

Klenod is a Ruby module bundler. It resolves URI-like module ids, transforms them through plugins, records a dependency graph, evaluates modules on demand, and can serialize a runtime-only bundle.

The design goal is close to Vite/Rollup/Parcel for graph and plugin behavior, with Ruby-native runtime values and optional NextJS/SvelteKit-inspired routing in a plugin.

## Package Boundaries

`Klenod::Build` owns development/build concerns:

- dependency resolution
- source loading
- plugin transforms
- graph collection
- invalidation
- development watching and update events
- asset generation
- runtime bundle serialization

`klenod-runtime` / `Klenod::Runtime` owns production loading:

- `Klenod::Runtime::Bundle`
- `Klenod::Runtime::Mod`
- serialized module specs
- runtime import values
- runtime asset specs
- source maps
- backtrace rewriting

Runtime must not require build plugins or plugin-only dependencies such as RMagick, `image_size`, Haml parsers, or CSS transformers.

`klenod-build` owns graph construction, plugins, the CLI, and development watching. It depends on `klenod-runtime`.

`klenod-rack` owns Rack-compatible asset serving helpers and depends only on `klenod-runtime`.

Optional integrations live outside the core graph/runtime boundary.

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

Module ids are canonical URI-like identifiers:

```ruby
import("./Card")
import("/components/Card")
import("virtual:router")
import("gem://klenod-ui/components/Card")
```

Files under the configured source directory use the hostless `app:` scheme internally, e.g. `app:/components/Card.haml`. Virtual modules use the hostless `virtual:` scheme, e.g. `virtual:/router.rb`. Plugin-owned module trees can use hostful schemes such as `gem://gem-name/path`. The built-in `GemImportPlugin` maps `gem://...` ids to files under a controlled import root inside installed gems.

Relative imports resolve from the importer using URL-style rules. That means `import("./Card")` and `import("Card")` both resolve next to the importing module. Leading-slash imports stay in the current scheme root, so `import("/components/Card")` from an app module resolves to `app:/components/Card`, while `import("/tokens.css")` from `gem://klenod-ui/components/Button.haml` resolves to `gem://klenod-ui/tokens.css`.

Use `app:/...` explicitly when code inside another scheme needs to import from the application source root. Unknown schemes must be handled by plugins before filesystem resolution, otherwise Klenod raises a `ResolveError`.

`import("...")` creates an eager dependency. `lazy_import("...")` records the dependency but returns a lazy runtime value that loads when called.

Eager cycles are errors. Lazy imports are the intended way to defer cyclic or expensive branches.

## Plugin Pipeline

Plugins can participate in several phases:

- `resolve(dependency, context)`: map a dependency to a module id.
- `load(module_id, context)`: provide source for virtual/custom modules, or a structured load result with a precomputed source hash and transform result.
- `transform(module_id, code, context)`: rewrite source and emit dependencies/assets/metadata.
- `finalize(module_id, result, resolved_dependencies, dependency_records, context)`: adjust transform output after dependencies are collected.
- `import_value(resolved_dependency, record, context)`: provide development/evaluation import values.
- `runtime_import_value(resolved_dependency, record, context)`: provide serialized bundle import values.

Collection hooks must not depend on evaluated app exports. Runtime import values must be serializable and must not require build-only dependencies.

Most modules flow through `load` as source strings and then through `transform`. Plugins that can do better than byte-backed source loading may return a `LoadResult`. Raster image imports use this path: the image plugin hashes the source file with a streaming file digest, reads dimensions from the path, and returns a completed transform result without asking the graph to `binread` the image into module source.

Sibling dependency loading can overlap. Plugins should avoid unguarded shared mutable state in `load` and `transform`.

## Runtime Modules

Each collected module is evaluated as a `Klenod::Runtime::Mod`.

Runtime modules get stable generated constant names so instances can be marshaled and unmarshaled. Transformed source is evaluated inside the generated runtime module, and exported values live under `Exports`.

Ruby and Haml modules generally assign `Default` for the default export. Importing a Haml file from Haml/Ruby returns the component class.

`__FILE__` is rewritten through runtime source-root handling so bundles can be built in one path and loaded in another. Source maps and backtrace rewriting handle transformed sources such as Haml. They are runtime-owned because production error pages need them without loading build plugins.

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

Build assets can hold bytes, generate bytes, or point at a source path. Source-path assets are used for original raster images so graph collection and module records do not retain image file contents. Writing such an asset copies from the source path to the output path; reading `asset.bytes` still works by reading from the source path or mirrored disk path when needed.

Generated assets use `queue_kind` to classify work. `:cpu` is the default and is used explicitly by image variants. `:io` is used by downloaded assets such as Google font files. `AssetGenerationQueue` keeps separate CPU and IO semaphores so IO-bound downloads can overlap with CPU-bound image resizing without allowing unbounded work.

Image variants remain generated CPU work. The image plugin passes RMagick an input source path when materializing a variant, so image decoding/resizing happens only when the variant is generated. RMagick still decodes pixel data in memory for resizing, but Klenod no longer stores the original image blob in the graph or closes over it in generated variant assets.

Runtime asset specs keep metadata only. Development servers/frameworks can serve assets from `context.asset(path).bytes` or `context.asset_bytes(path, assets_dir:)`.

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

External CSS-like imports can be handled by adjacent plugins instead of overloading the CSS plugin. `GoogleFontsPlugin` resolves Google Fonts CSS URLs, downloads the CSS during collection to discover font files, rewrites font URLs to local asset paths, and emits font files as lazy IO-generated assets. It also uses a vendored, attributed [Capsize](https://github.com/seek-oss/capsize) metrics snapshot to emit `"<Family> Fallback"` faces with CSS metric overrides; applications explicitly include those generated family names in their font stacks. The default fetcher uses one `Async::HTTP::Internet` instance so multiple font downloads can reuse HTTP clients while remaining bounded by the IO queue.

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
- Whitespace handling should use Haml parser node flags such as `nuke_inner_whitespace` and `nuke_outer_whitespace`; avoid source-line based marker detection in later transform phases.

The factory API currently expects:

```ruby
def self.[](tag, *children, **props)
end
```

## Router Plugin

Routing is optional and plugin-owned. Core Klenod should not assume web routing.

`RouterPlugin` discovers routes under a configured pages directory and generates `virtual:router`.

Supported route files:

- `+page.rb`
- `+page.haml`
- `+route.rb`
- `+layout.rb`
- `+layout.haml`
- `+error.rb`
- `+error.haml`
- `+not-found.rb`
- `+not-found.haml`

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

A directory can contain both a page and `+route.rb`. The router exposes both; the framework decides which one to use for a request.

When no page route matches, the router resolves the closest `not-found` module for the URL path. When a page render raises, the example framework renders the closest `error` module for the failed route. Error and not-found pages use layouts closest to the fallback module being rendered, not necessarily layouts closest to the originally requested page.

The example server follows SvelteKit-style dispatch:

- `PUT`, `PATCH`, `DELETE`, and `OPTIONS` always use `+route.rb`.
- `GET`, `POST`, and `HEAD` render the page when `Accept` prefers `text/html`.
- Other `GET`, `POST`, and `HEAD` requests use `+route.rb`.
- Hybrid `GET` handler responses include `Vary: Accept`.

The router should stay request-agnostic. Request dispatch belongs in the framework/server layer.

## Development Updates

`Klenod::Build::Watcher` watches source files and asks the build graph to invalidate affected modules.

Invalidation considers:

- changed module source files
- removed module files
- changed dependencies
- watched patterns such as Haml companion CSS and intl files
- virtual modules such as `virtual:router`

Collected-but-not-evaluated modules should remain unevaluated after invalidation. `apply_update` should not force entry evaluation unless the entry was already evaluated or the caller explicitly asks for exports/calls.

Failed reloads are represented in the graph rather than discarded silently. When a changed module fails to transform or collect, the graph stores a failed `ModuleRecord` with the original error and reports that module as the update error. Dependents of that failed reload are not reevaluated during the same update, which avoids repeatedly parsing/importing the same broken module. Already evaluated dependents are evicted, so a later request that actually needs the failed dependency re-evaluates and raises the stored error instead of continuing to use stale exports. Routes that do not depend on the failed module can continue to render from the previous good graph.

Graph dependency loading may run sibling loads concurrently. Worker tasks capture expected build/parse failures as result values and re-raise them from the parent graph path. This keeps errors attributable to the update/request that caused them and avoids noisy `Async::Task` unhandled-exception warnings for normal development syntax errors.

Frameworks can subscribe to updates:

```ruby
context.on_update do |event|
  update = context.apply_update(event, entry: entry, assets_dir: "public")
end
```

The example web server formats update errors and request errors consistently. It remembers recently logged errors for a short interval so an update failure plus immediate browser follow-up requests do not flood the console, while later failed requests still report their error.

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

The example framework also owns request error policy: it maps explicit `NotFoundError` failures to 404 rendering, maps other render exceptions to 500 rendering, and logs formatted backtraces/source context to the console. These behaviors document one integration style rather than core router policy.

## Open Design Areas

The main areas still evolving:

- Further external import plugin polish for package-owned Klenod module trees.
- More precise route visualization and route ordering tools.
- Broader async rendering semantics beyond the example framework's fiber-local request context.
- A future `klenod dev` command or TUI, if it can remain framework-neutral.
- Splitting build/dev/runtime into separate gems after the boundaries settle.
