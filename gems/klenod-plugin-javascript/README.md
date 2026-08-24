# klenod-plugin-javascript

JavaScript asset plugin for Klenod, powered by [SWC](https://swc.rs/).

Importing a JavaScript file adds it to the Klenod module graph. Local static
imports, re-exports, and string-literal dynamic imports become graph
dependencies and are collected recursively. Each module is emitted as a
content-hashed asset, and its import specifiers are rewritten to the emitted
dependency paths.

The plugin supports `.js`, `.ts`, `.jsx`, and `.tsx` files. SWC transforms
TypeScript and JSX, and JSX uses Klenod's helper to create HTML elements for
custom-element implementations. External URL imports are preserved; bare
package imports and npm resolution are not currently supported.

## Options

```ruby
Klenod::Build::Plugins::JavaScriptPlugin::Plugin.new(
  source_maps: :development,
  minify: false
)
```

- `source_maps:` accepts `false`, `true`, or `:development` (the default).
- `minify:` also minifies in development when `true`; build output is always
  minified.
