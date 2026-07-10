# Klenod

Klenod is an experimental Ruby module bundler inspired by Vite, Rollup, Parcel, and Webpack. It loads files from a configured source directory, transforms them through plugins, evaluates them as stable `Klenod::Runtime::Mod` instances, and can serialize a runtime-only bundle with `Marshal.dump`.

The project is still early, but the core shape is in place:

- `Klenod::Build` owns resolving, transforms, plugins, graph construction, bundling, and emitted assets.
- `Klenod::Dev` owns source watching and graph update events.
- `Klenod::Runtime` owns production bundle loading without depending on build plugins.

## Basic Usage

Create a build context with a source directory:

```ruby
context = Klenod::Build::Context.new(source_dir: "src")
entry = context.entry("pages/server")
page = entry.exports
```

Ruby modules can import other modules with literal `import("...")` calls. Relative imports resolve from the importing file, while absolute imports are scoped to the configured source directory.

```ruby
Shared = import("../shared")
Styles = import("styles/home.css")
Hero = import("./hero.png?width=320,640&format=png")
```

## Entry Handles

Frameworks should usually keep a loaded entry handle instead of storing raw graph records:

```ruby
entry = context.entry("pages/server")
status, headers, body = entry.call(request, context)
page = entry.exports
stylesheets = entry.assets(type: :css)
```

`entry.call(...)` delegates to the current exports object, which is useful for callable entries. `entry.exports` always resolves through the current graph state, so the same handle can be reused after development updates. `entry.assets` returns assets reachable from that entry and is recursive by default; pass `recursive: false` to include only assets emitted directly by the entry module.

Watch-mode consumers can apply a graph update and keep using the same entry handle:

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

`apply_update` refreshes the entry, mirrors changed assets when `assets_dir:` is provided, and returns an applied update object with `entry`, `exports`, `asset_write_result`, and `errors`. Use `update.success?`, `update.failed?`, `update.error_messages`, and `update.asset_files_changed?` for common watch-mode branches.

Use `lazy_import("...")` to record a dependency without loading it while the importing module is evaluated. It returns a `Klenod::Runtime::LazyImport`; call `#call` or `#value` to load and cache the imported value.

```ruby
Details = lazy_import("./details")

def self.render_details
  Details.call::Default.new.render
end
```

Build output can be serialized for runtime loading:

```ruby
bundle = context.build(
  entrypoints: ["pages/server"],
  output: "dist/klenod.bundle",
  assets_dir: "public"
)
```

The same build path is available through the CLI:

```sh
bundle exec exe/klenod build \
  --source src \
  --entry pages/server \
  --output dist/klenod.bundle \
  --assets-dir public
```

The runtime side can load the bundle without build plugins:

```ruby
bundle = Klenod::Runtime.load_bundle("dist/klenod.bundle")
page = bundle.exports("pages/server")
```

## Asset Conventions

Plugins emit assets through `Klenod::Build::Asset`. Assets have two stable identifiers:

- `logical_name`: the source-root-relative file path without import query parameters, such as `images/hero.png`.
- `output_path`: the public, content-hashed path served to browsers, such as `/assets/hero.320w.abc123.png`.

The graph and runtime bundle expose the same lookup shape:

```ruby
context.asset("/assets/home.abc123.css")
context.assets_for("styles/home.css")
context.assets_for_module("pages/server.rb", type: :css)

bundle.asset("/assets/home.abc123.css")
bundle.assets_for("styles/home.css")
bundle.assets_for_module("pages/server.rb", type: :css)
```

`assets_for_module` is recursive by default. Pass `recursive: false` to return only assets directly emitted by that module.

Build assets keep bytes so they can be served in development or written to disk. Runtime asset specs keep only metadata, content hashes, content types, logical names, and output paths.

When `Context#build` receives `assets_dir:`, emitted assets are written under that directory using their public path without the leading slash. For example, `/assets/home.abc123.css` becomes `public/assets/home.abc123.css`.

Import query parameters configure a specific import without changing the asset's logical name. For example, both of these imports belong to `images/hero.png`, and overlapping generated variants are reused:

```ruby
LargeHero = import("images/hero.png?width=640&format=png")
ResponsiveHero = import("images/hero.png?width=320,640&format=png")
```

In development, frameworks using Klenod are expected to serve `context.asset(path).bytes` for requested asset paths and listen to update events from `Klenod::Dev::Watcher`.

## Router Plugin

Routing is provided by the optional `RouterPlugin`, not by the core build context. Add it to a context and import its virtual module:

```ruby
router_plugin = Klenod::Build::Plugins::RouterPlugin.new

context = Klenod::Build::Context.new(
  source_dir: "src",
  plugins: [
    Klenod::Build::Plugins::RubyPlugin.new,
    router_plugin
  ]
)

router = context.entry("virtual:router").exports::Default
match = router.match("/blog/hello")
match.params
# => {slug: "hello"}
match.page
# => exports for pages/blog/[slug]/page.rb or page.haml
```

Only `page.rb` and `page.haml` files are route entrypoints for now. For example, `pages/page.haml` maps to `/`, and `pages/blog/page.rb` maps to `/blog`. Layouts and path params are represented structurally; layout composition and rendering stay in the framework layer.

The router plugin preserves NextJS-style structure:

- `[id]` becomes a dynamic segment with path part `:id`.
- `[...slug]` becomes a catch-all segment with path part `*slug`.
- `[[...slug]]` is preserved as an optional catch-all segment.
- `(marketing)` is preserved as a route group and does not add a URL path part.
- `@modal` is preserved as a parallel route slot and does not add a URL path part.
- `(.)photo`, `(..)profile`, and `(...)login` are preserved as intercepted route segments with visible path parts.

The generated router also exposes a structural route tree:

```ruby
tree = router.tree
tree.children
tree.route
tree.slots.fetch(:modal)
```

Tree nodes expose `segment`, `path`, `route`, `children`, `slots`, `root?`, and `leaf?`. Parallel route slots are available through `node.slots`, while still remaining in `node.children` for structural traversal.

In development mode, the generated router uses `lazy_import` for pages and layouts so matching a route can load only the selected page. In build mode, it uses eager `import` so bundles include the full route graph.

## Plugins

The default build context includes plugins for Ruby, intl TOML files, Haml adapter output, CSS, and images. Plugins can:

- resolve dependencies,
- load source content,
- transform source,
- emit assets,
- add watched companion file patterns,
- provide import values for the importing module.

CSS imports currently return class-name maps for Ruby or Haml importers. Image imports return an image object with `src`, dimensions, and generated `variants`.

Sibling dependency modules may be loaded concurrently. Plugin hooks should avoid unguarded shared mutable state, because `load` and `transform` calls for independent modules can overlap. `finalize` still runs after eager dependencies for that module have loaded.

Assets can be static or generated. Generated assets expose metadata immediately and generate bytes on demand; call `asset.wait` before serving or writing an asset when the bytes may not be ready yet. Failed generation marks the asset as failed and exposes `asset.error`. Build mode drains generated assets before writing the bundle.

Generated asset work runs through a build-owned queue. Configure it with `asset_generation_concurrency:` when creating a build context.

```ruby
asset = context.asset(request.path)
bytes = context.asset_bytes(request.path, assets_dir: "public")

[
  200,
  {"content-type" => asset.content_type},
  [bytes]
]
```

## Development

Run the test suite with:

```sh
bundle exec rake
```

The example app can be run from the repository root:

```sh
bundle exec ruby example/server.rb
```

It starts a small `async-http` server, serves emitted assets from the build context, and watches the source tree for graph updates.
