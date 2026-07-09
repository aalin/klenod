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
record = context.load("pages/server")
page = context.graph.mods.fetch(record.id).const_get(:Exports)
```

Ruby modules can import other modules with literal `import("...")` calls. Relative imports resolve from the importing file, while absolute imports are scoped to the configured source directory.

```ruby
Shared = import("../shared")
Styles = import("styles/home.css")
Hero = import("./hero.png?width=320,640&format=png")
```

Build output can be serialized for runtime loading:

```ruby
bundle = context.build(
  entrypoints: ["pages/server"],
  output: "dist/klenod.bundle",
  assets_dir: "public"
)
```

The runtime side can load the bundle without build plugins:

```ruby
bundle = Klenod::Runtime.load_bundle("dist/klenod.bundle")
page = bundle.load("pages/server")
```

## Asset Conventions

Plugins emit assets through `Klenod::Build::Asset`. Assets have two stable identifiers:

- `logical_name`: the source-root-relative file path without import query parameters, such as `images/hero.png`.
- `output_path`: the public, content-hashed path served to browsers, such as `/assets/hero.320w.abc123.png`.

The graph and runtime bundle expose the same lookup shape:

```ruby
context.asset("/assets/home.abc123.css")
context.assets_for("styles/home.css")

bundle.asset("/assets/home.abc123.css")
bundle.assets_for("styles/home.css")
```

Build assets keep bytes so they can be served in development or written to disk. Runtime asset specs keep only metadata, content hashes, content types, logical names, and output paths.

When `Context#build` receives `assets_dir:`, emitted assets are written under that directory using their public path without the leading slash. For example, `/assets/home.abc123.css` becomes `public/assets/home.abc123.css`.

Import query parameters configure a specific import without changing the asset's logical name. For example, both of these imports belong to `images/hero.png`, and overlapping generated variants are reused:

```ruby
LargeHero = import("images/hero.png?width=640&format=png")
ResponsiveHero = import("images/hero.png?width=320,640&format=png")
```

In development, frameworks using Klenod are expected to serve `context.asset(path).bytes` for requested asset paths and listen to update events from `Klenod::Dev::Watcher`.

## Page Discovery

Frameworks can discover app-style pages under `pages/`:

```ruby
context.page_routes
# => [#<data Klenod::Build::PageRoute path="/" module_id=pages/page.haml>]

manifest = context.route_manifest
manifest.entrypoints
# => ["pages/page.haml"]
```

Only `page.rb` and `page.haml` files are route entrypoints for now. For example, `pages/page.haml` maps to `/`, and `pages/blog/page.rb` maps to `/blog`. Layouts and path params are represented structurally, but request matching and layout composition are left to a router/framework layer.

Routes also expose parsed segments for future router layers. The discovery layer preserves NextJS-style structure without deciding rendering policy:

- `[id]` becomes a dynamic segment with path part `:id`.
- `[...slug]` becomes a catch-all segment with path part `*slug`.
- `[[...slug]]` is preserved as an optional catch-all segment.
- `(marketing)` is preserved as a route group and does not add a URL path part.
- `@modal` is preserved as a parallel route slot and does not add a URL path part.

`PageRoute#params` returns structural parameter metadata for dynamic, catch-all, and optional catch-all segments. Request matching and parameter extraction are left to the router/framework layer.

`PageRoute#layout_module_ids` lists discovered `layout.haml` files from outermost to nearest layout. This is structural only; Klenod does not load or compose layouts during discovery.

## Plugins

The default build context includes plugins for Ruby, intl TOML files, Haml adapter output, CSS, and images. Plugins can:

- resolve dependencies,
- load source content,
- transform source,
- emit assets,
- add watched companion file patterns,
- provide import values for the importing module.

CSS imports currently return class-name maps for Ruby or Haml importers. Image imports return an image object with `src`, dimensions, and generated `variants`.

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
