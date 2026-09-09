# klenod-plugin-javascript

JavaScript asset plugin for [Klenod](https://github.com/aalin/klenod), powered
by [SWC](https://swc.rs/).

It:

- collects static imports, re-exports, and string-literal dynamic imports
- transforms JavaScript, TypeScript, JSX, and TSX
- rewrites graph imports to content-hashed asset paths
- emits image and SVG wrappers backed by shared `ImageBase`, `ImageMetadata`, `ImageVariant`, and `SvgMetadata` classes, with frozen concrete metadata values, only for assets imported from JavaScript
- preserves external URL imports

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

`NodeModulesPlugin` adds npm packages to the Klenod graph. It is opt-in; register
it before `JavaScriptPlugin` so the JavaScript plugin can transform the files it
resolves:

```ruby
plugins [
  Klenod::Build::Plugins::NodeModulesPlugin.new,
  Klenod::Build::Plugins::JavaScriptPlugin.new
]
```

Use an explicit `npm://` URL from application code. This keeps package lookup
separate from Klenod's usual rule that a bare specifier is relative to its
importer.

```js
import * as THREE from "npm://three";
import { vec3 } from "npm://gl-matrix";
import { OrbitControls } from "npm://three/addons/controls/OrbitControls.js";
import { ReactiveElement } from "npm://@lit/reactive-element";
import { css } from "npm://@lit/reactive-element/css-tag.js";
```

The part after `npm://` is the package name, followed by an optional exported
subpath. Scoped names retain the usual `@scope/package` form. The scheme works
with static imports, side-effect imports, re-exports, and string-literal dynamic
imports:

```js
import "npm://@scope/widget";
export { html } from "npm://lit";
button.addEventListener("click", () => import("npm://three"));
```

Exported subpaths must match the package's `exports` map. Include an extension
when the export includes one: use
`npm://three/addons/controls/OrbitControls.js` for Three.js, but
`npm://zod/mini` for Zod.

`NodeModulesPlugin` selects package exports using the `browser`, `import`,
`module`, and `default` conditions. It respects the order of conditions in
`package.json`. Packages without `exports` fall back to `module`, then `main`,
then `index.js`.

Once inside an npm package, relative imports continue within that package and
bare specifiers resolve its dependencies from the nearest `node_modules`
directory. Package self-references and `#` imports are supported through the
package's `exports` and `imports` maps. Extensionless package imports probe
`.js`, `.mjs`, `index.js`, and `index.mjs`; targets from an `exports` map are
exact and are not probed.

Resolved package files are ordinary graph modules. Klenod transforms them,
rewrites their imports, emits content-hashed assets, and minifies them in build
mode.

### Configuration

- `root:` overrides the `node_modules` directory. By default the nearest one at
  or above the source directory is used.
- `conditions:` overrides the matched export conditions. The default is
  `browser`, `import`, `module`, and `default`, matched in the order the package
  lists them.

### Compatibility

Only ES modules are supported. CommonJS packages, Node builtins, the legacy
`browser` field, and JSON package imports are not supported. A `browser`
condition inside `exports` is supported.

Each package name can refer to only one physical directory in a graph because
module IDs use the form `npm://<package>/<path>`. If resolution finds two copies
of a package, Klenod reports the conflict; deduplicate that package in the
lockfile.
