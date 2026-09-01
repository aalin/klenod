# klenod-plugin-javascript

JavaScript asset plugin for [Klenod](https://github.com/aalin/klenod), powered
by [SWC](https://swc.rs/).

It:

- collects static imports, re-exports, and string-literal dynamic imports
- transforms JavaScript, TypeScript, JSX, and TSX
- rewrites local imports to content-hashed asset paths
- emits image and SVG wrappers backed by shared `ImageBase`, `ImageMetadata`, `ImageVariant`, and `SvgMetadata` classes, with frozen concrete metadata values, only for assets imported from JavaScript
- preserves external URL imports

Bare package imports and npm resolution are not currently supported.

## Options

```ruby
require "klenod/plugin/javascript"

Klenod::Build::Plugins::JavaScriptPlugin.new(
  source_maps: :development,
  minify: false
)
```

- `source_maps:` accepts `false`, `true`, or `:development` (the default).
- `minify:` also minifies in development when `true`; build output is always
  minified.
