# klenod-plugin-javascript

JavaScript asset plugin for [Klenod](https://github.com/aalin/klenod), powered
by [SWC](https://swc.rs/).

It:

- collects static imports, re-exports, and string-literal dynamic imports
- transforms JavaScript, TypeScript, JSX, and TSX
- rewrites local imports to content-hashed asset paths
- emits image and SVG wrappers backed by shared `ImageBase`, `ImageMetadata`, `ImageVariant`, and `SvgMetadata` classes, with frozen concrete metadata values, only for assets imported from JavaScript
- preserves external URL imports

Bare package specifiers stay relative to the importer, as they are everywhere
else in Klenod. Import npm packages through the `npm://` scheme instead.

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

## npm Packages

`NodeModulesPlugin` resolves `npm://` imports against an installed
`node_modules` directory. Register it before `JavaScriptPlugin`:

```ruby
plugins [
  Klenod::Build::Plugins::NodeModulesPlugin.new,
  Klenod::Build::Plugins::JavaScriptPlugin.new
]
```

```js
import * as THREE from "npm://three";
import { OrbitControls } from "npm://three/addons/controls/OrbitControls.js";
import { vec3 } from "npm://gl-matrix";
```

Packages resolve through the `exports` field, falling back to `module` and then
`main` when a package has none. Package files go through the graph like any
other module, so they are transformed, content-hashed, and minified in build
mode.

Only ES modules are supported. The `require` condition is deliberately not
matched, so a CommonJS-only package fails when it is resolved rather than in the
browser.

- `root:` overrides the `node_modules` directory. By default the nearest one at
  or above the source directory is used.
- `conditions:` overrides the matched export conditions. The default is
  `browser`, `import`, `module`, and `default`, matched in the order the package
  lists them.

Imports between npm packages, extensionless imports inside a package, and the
legacy `browser` field are not supported yet.
