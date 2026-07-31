# Built-in Build Plugins

This directory contains the built-in plugins for `klenod-build`.

Plugins can:

- resolve dependencies
- load source content
- transform source
- emit assets
- add watched companion file patterns
- provide import values
- provide runtime import values

Collection hooks run before application code evaluation. Runtime import values must serialize cleanly and must not require build-only dependencies.

Read [Graph And Plugin Phases](../../../../../../docs/graph-and-plugin-phases.md) for the full collection and evaluation model.

## Hook Summary

Plugins participate in graph collection through these hooks:

- `resolve`: maps a dependency to a module id.
- `load`: provides source for virtual modules or custom files.
- `transform`: rewrites source and records dependencies, assets, metadata, source maps, and watched patterns.
- `finalize`: adjusts a transform after eager dependency records are collected.
- `import_value`: provides the value that development code receives from an evaluated import.
- `runtime_import_value`: provides the value or instruction that a runtime bundle stores.

Plugins can also implement `invalidate_module_ids` for custom invalidation and `emit_assets` for assets derived from collected records.

## Default Plugin Set

`Klenod::Build::Context.default_plugins` includes:

- `RubyPlugin::Plugin`
- `IntlPlugin::Plugin`
- `HamlPlugin::Plugin`
- `MarkdownPlugin::Plugin`
- `CssPlugin::Plugin`
- `SvgPlugin::Plugin`
- `ImagePlugin::Plugin`
- `JsonPlugin::Plugin`
- `YamlPlugin::Plugin`
- `TomlPlugin::Plugin`
- `TextPlugin::Plugin`

`GoogleFontsPlugin::Plugin` and `RouterPlugin::Plugin` are built in but opt-in. The example web app configures both explicitly.

Each built-in plugin namespace exposes its entry point as `Plugin`, leaving room for helpers, errors, and value objects beside the plugin class.

## RubyPlugin

Handles `.rb` modules.

- Rewrites `import(...)` and `lazy_import(...)` calls into Klenod runtime imports.
- Rewrites `import_glob(...)` calls into deterministic import hashes.
- Collects Ruby import dependencies.
- Records watched patterns for glob imports so file add/remove updates invalidate the importer.
- Leaves non-Ruby files untouched.

Configuration: none.

Glob imports are eager by default:

```ruby
Images = import_glob("./gallery/*.{jpg,png}?width=320&format=webp")
```

The returned hash uses matched path specifiers without query strings as keys.

The query string applies to each generated dependency. Use `eager: false` for lazy values:

```ruby
Pages = import_glob("./pages/*.rb", eager: false)
```

## HamlPlugin

Handles `.haml` modules.

- Transforms Haml templates into Ruby component classes exported as `Default`.
- Rewrites Haml-side imports.
- Supports `import_glob(...)` in Haml Ruby code and Ruby filters.
- Supports `:markdown` filters rendered through factory calls.
- Supports Haml component references such as `%Card`.
- Adds companion dependencies for `Component.css` and translations from `Component.intl.*.toml`.
- Emits source maps so runtime errors can be mapped back to Haml source.

Configuration:

```ruby
Klenod::Build::Plugins::HamlPlugin::Plugin.new(
  component_base_class: "Example::Component",
  factory: "Example::H",
  global_variables: "@__props",
  cache_static_subtrees: false
)
```

- `component_base_class`: Ruby constant path used as the generated component superclass. Defaults to `"Object"`.
- `factory`: Ruby constant path used for generated HTML/component calls. Defaults to `"Object"`.
- `global_variables`: optional Ruby expression used to rewrite app-style global variable reads in Haml Ruby code. For example, `global_variables: "@__props"` compiles `$title` to `@__props[:title]`. Built-in Ruby globals such as `$!`, `$1`, and `$LOAD_PATH` are left untouched.
- `cache_static_subtrees`: optional experimental optimization. When enabled, fully static Haml tag subtrees are compiled once into frozen constants and reused across renders. Defaults to `false`.

`:markdown` filters use `MarkdownPlugin::Plugin`'s source-root component map convention when `markdown-components.rb` exists.

## MarkdownPlugin

Handles `.md` modules and Haml `:markdown` filters through `kramdown` with the GFM parser.

- Transforms Markdown files into Ruby component classes exported as `Default`.
- Parses optional YAML frontmatter and exposes it as `Default::Frontmatter`.
- Renders Markdown elements as factory calls, not raw HTML strings.
- Converts raw HTML elements in Markdown into factory calls too.
- Uses `/markdown-components.rb` when present to map Markdown tags to components.

Configuration:

```ruby
Klenod::Build::Plugins::MarkdownPlugin::Plugin.new(
  component_base_class: "Example::Component",
  factory: "Example::H"
)
```

Markdown component map convention:

```ruby
# src/markdown-components.rb
Heading = import("/components/MarkdownHeading.haml")
Link = import("/components/MarkdownLink.haml")

Default = {
  h1: Heading,
  a: Link
}.freeze
```

Unmapped tags fall back to symbol tags such as `:p`, `:a`, and `:code`.

Markdown modules and Haml modules with `:markdown` filters watch `markdown-components.rb`. Adding, editing, or removing the map reloads affected modules.

## IntlPlugin

Provides translation helpers for Haml companion files.

- Looks for files matching `Component.intl.<locale>.toml`.
- Parses them with `toml-rb`.
- Returns translations keyed by locale.

Configuration: none.

`HamlPlugin::Plugin` uses this plugin. It does not transform standalone modules.

## CssPlugin

Handles `.css` modules through `mayu-css`.

- Transforms and scopes CSS selectors.
- Emits browser stylesheet assets.
- Ruby/Haml imports receive a class-name map.
- CSS imports from CSS become stylesheet dependencies.
- CSS `url(...)` references become asset dependencies.
- Can emit standard v3 `.css.map` assets with mapped dependency rewrites.

Configuration:

```ruby
Klenod::Build::Plugins::CssPlugin::Plugin.new(
  source_maps: :development
)
```

- `source_maps`: `false`, `true`, or `:development`. Defaults to `:development`, which emits source maps only when the build context mode is `:development`.

## GoogleFontsPlugin

Handles Google Fonts CSS imports such as `https://fonts.googleapis.com/css2?...`.

- Resolves Google Fonts CSS URLs imported from CSS.
- Downloads the raw Google CSS, optionally through a persistent raw-CSS cache.
- Parses `@font-face` metadata.
- Rewrites `fonts.gstatic.com` font URLs to local emitted font assets.
- Emits the rewritten Google Fonts CSS as a normal CSS asset.
- Emits font files as lazy IO-generated assets.

Configuration:

```ruby
Klenod::Build::Plugins::GoogleFontsPlugin::Plugin.new(
  fetcher: nil,
  cache_path: nil,
  refresh_cache: false
)
```

- `fetcher`: optional object/lambda used for downloading. It must respond to `call(url)`. If it also responds to `write(url, io)`, font downloads stream through that method.
- `cache_path`: optional directory for raw Google CSS responses, keyed by full URL. `nil` disables the cache.
- `refresh_cache`: when true, fetches and replaces cached CSS even if a cached response exists.

## SvgPlugin

Handles `.svg` modules.

- Emits the SVG file as a browser asset.
- Exports metadata with `src`, `width`, and `height`.
- Reads dimensions from `<svg width height>` or derives them from `viewBox`.
- Rejects query parameters for SVG imports.

Configuration: none.

## ImagePlugin

Handles raster image modules:

- `.avif`
- `.gif`
- `.jpeg`
- `.jpg`
- `.png`
- `.webp`

Behavior:

- Uses path-backed loading so original image bytes are not stored in graph records.
- Computes source hashes with a streaming file digest.
- Reads dimensions from the source path with `image_size`.
- Emits the original image as a source-path asset unless import query parameters require a generated default asset.
- Emits resized variants as generated CPU assets using RMagick.
- Exports an image metadata object with `src`, `width`, `height`, `content_type`, `variants`, `srcset`, and `sizes`.

Configuration:

```ruby
Klenod::Build::Plugins::ImagePlugin::Plugin.new(
  widths: [320, 640, 960],
  formats: ["webp", "jpeg"]
)
```

- `widths`: default variant widths when an import does not provide `?width=...`.
- `formats`: default variant formats when an import does not provide `?format=...`. Defaults to the source file format.

Import query parameters:

```ruby
import("hero.jpg?width=320,640&format=webp,jpeg&quality=82")
```

`format` applies to variants. When explicitly provided, it also applies to the default `src` asset.

`quality` applies to generated default and variant assets for image formats that support it.

Overlapping variants from separate imports are deduplicated by source path, source hash, width, format, and quality.

## DataPlugin And Data Formats

`DataPlugin` is a base class for structured/text data import plugins.

Built-in subclasses:

- `JsonPlugin`: `.json`, parsed with `JSON.parse`.
- `YamlPlugin`: `.yaml`, `.yml`, parsed with `YAML.safe_load`.
- `TomlPlugin`: `.toml`, parsed with `TomlRB.parse`.
- `TextPlugin`: `.txt`, `.text`, imported as strings.

Behavior:

- Transforms supported files into Ruby modules exporting `Default`.
- Development imports return the parsed/default value.
- Runtime bundle imports serialize the parsed data directly.

Configuration: none for built-in subclasses.

## RouterPlugin

Generates an optional virtual router module.

- Discovers page, route, layout, error, and not-found modules under a pages directory.
- Supports dynamic, catch-all, optional catch-all, route-group, parallel, and intercepted route segment syntax.
- Uses lazy imports in generated router code so route modules are not evaluated at startup.
- Exposes route matches with page, handler, layouts, slots, params, and route metadata.

Configuration:

```ruby
Klenod::Build::Plugins::RouterPlugin::Plugin.new(
  specifier: "virtual:router",
  pages_dir: "pages",
  extensions: [".rb", ".haml"],
  route_base_class: "Example::Route"
)
```

- `specifier`: import specifier for the generated router module.
- `pages_dir`: source-root-relative directory to scan.
- `extensions`: page/layout/route implementation extensions.
- `route_base_class`: optional Ruby constant path used for generated route metadata classes.
