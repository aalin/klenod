# AGENTS.md

Guidance for future agent sessions working on Klenod.

## Project Shape

Klenod is an experimental Ruby module bundler inspired by Vite, Rollup, Parcel, Webpack, NextJS routing, and SvelteKit route handlers.

Keep these boundaries intact:

- `lib/klenod/build/`: graph collection, resolving, plugins, transforms, asset generation, bundle writing.
- `lib/klenod/runtime/`: runtime bundle loading, module evaluation, source maps, and backtrace rewriting. Runtime must not require build plugins or heavyweight build dependencies.
- `lib/klenod/rack/`: Rack-compatible serving helpers, not framework policy.
- `gems/`: gemspecs for `klenod-runtime`, `klenod-build`, `klenod-rack`, and the compatibility `klenod` meta gem.
- `example/web/`: framework-style example app using router, Haml, CSS, assets, sessions, forms, route handlers, and `async-http`.
- `example/standalone/`: non-web example for executable bundles and data imports.

Read these first when continuing architecture work:

- `README.md`
- `PLAN.md`
- `ARCHITECTURE.md`
- `docs/graph-and-plugin-phases.md`
- `example/web/README.md`

## Development Workflow

Use co-located tests:

- Test files use `*.test.rb`.
- Fixtures live in a sibling `__test__/` directory near the implementation.
- Haml transform golden tests live under `lib/klenod/build/plugins/__test__/haml`.

Useful focused commands:

```sh
bundle exec ruby lib/klenod/build/context.test.rb
bundle exec ruby lib/klenod/build/plugins/router_plugin.test.rb
bundle exec ruby lib/klenod/build/plugins/haml_plugin.test.rb
bundle exec ruby lib/klenod/runtime/mod.test.rb
bundle exec ruby example/web/example.test.rb
bundle exec ruby example/standalone/example.test.rb
```

Run Standard on changed Ruby files:

```sh
RUBOCOP_CACHE_ROOT=/private/tmp/rubocop_cache bundle exec standardrb path/to/file.rb ...
```

The cache root matters in sandboxed environments. Plain `standardrb` may try to write under `~/.cache` and fail.

Example app commands:

```sh
example/web/bin/build
example/web/bin/run
example/web/bin/routes
example/web/bin/server
```

CLI build from config:

```sh
cd example/web
bundle exec ../../exe/klenod build
```

## Core Architecture Rules

Graph collection and module evaluation are separate:

- Collected means the source was read, transformed, dependency records were collected, assets were emitted, and a `ModuleRecord` exists.
- Evaluated means a `Klenod::Runtime::Mod` was instantiated and the module's Ruby top-level code ran.
- `context.entry(...)` and `context.collect(...)` should collect without evaluating app code.
- `entry.exports`, `entry.call(...)`, `context.exports(...)`, and `context.evaluate(...)` evaluate on demand.
- Build mode should serialize collected records without evaluating app modules.

Development invalidation should preserve this split:

- If a changed module fails to reload, store a failed `ModuleRecord` for that module and keep the original reload error as the root error.
- Do not reevaluate dependents of a failed reload during the same update; that would parse/import the same broken module repeatedly and produce duplicate errors.
- Do evict evaluated dependent mods, so a later request that actually needs the broken dependency re-evaluates and raises the stored error instead of using stale exports.
- Unrelated routes/modules should continue using the previous good graph when they do not depend on the failed module.
- Async graph worker tasks should capture failures as values and re-raise from the parent path; expected parse/build errors must not leak as `Async::Task: Task may have ended with unhandled exception`.

Plugin hook phases:

- `resolve`, `load`, `transform`, and `finalize` are collection-time hooks.
- `import_value` is for development/evaluation.
- `runtime_import_value` is for bundle serialization and must not depend on evaluated app exports.

Imports:

- `import("./foo")` resolves relative to the importer.
- `import("/foo")` resolves from the configured source root.
- `lazy_import("...")` records a dependency but defers loading/evaluation until called.
- Future external imports should probably use explicit schemes such as `plugin:` or `gem:`; do not overload `/foo`.

Cycles:

- Eager import cycles should produce useful cycle-chain errors.
- Lazy imports are the escape hatch for deferred dependency loading.

## Runtime Boundary

The runtime side must stay production-safe:

- Runtime should load bundles and evaluate modules without build plugins.
- Do not put plugin data objects that require build dependencies into runtime bundles.
- If runtime needs a value type, define it under `Klenod::Runtime` or as a virtual module/value that serializes cleanly.
- Image import runtime values should not require RMagick or `image_size`.

Executable bundle output prepends Ruby source and stores marshal data after `__END__` with binary encoding. Runtime loading scans/loads the marshal payload; the file is not meant to be editor-friendly.

## Router Rules

Routing belongs to `RouterPlugin`; it should stay optional and framework-agnostic.

The router supports:

- `page.rb` and `page.haml`.
- `route.rb` handlers.
- Hybrid directories with both a page and `route.rb`.
- `layout.rb`/`layout.haml`.
- `error.rb`/`error.haml`.
- `not-found.rb`/`not-found.haml`.
- Dynamic segments: `[id]`.
- Catch-all segments: `[...slug]`.
- Optional catch-all segments: `[[...slug]]`.
- Route groups: `(marketing)`.
- Parallel routes: `@modal`, `@sidebar`.
- Intercepted routes: `(.)photo`, `(..)profile`, `(...)login`.

Generated router modules should use lazy imports so development does not load every page at startup.

`Router::Default.match(path)` returns a match with:

- `match.page`
- `match.handler`
- `match.layouts`
- `match.slots`
- `match.params`
- `match.route`

When no page route matches, the generated router should resolve the closest `not-found` module for that URL path. When rendering raises, the example framework renders the closest `error` module for the failing page. Layouts are chosen relative to the error/not-found module being rendered, not the originally requested page.

Hybrid route behavior is framework/server policy, not router policy. The example web server follows SvelteKit-style rules:

- `PUT`, `PATCH`, `DELETE`, and `OPTIONS` go to `route.rb`.
- `GET`, `POST`, and `HEAD` render the page if `Accept` prefers `text/html`.
- Otherwise they go to `route.rb`.
- Hybrid `GET` handler responses should include `Vary: Accept`.

`example/web/bin/routes` is the current route visualization tool. It prints a table and a tree. Route display ordering still needs a future pass so it follows actual router match priority.

## Haml Rules

The Haml plugin is an adapter, not a framework renderer:

- Rendering logic lives outside Klenod.
- Configure a component base class, e.g. `component_base_class: "Example::Component"`.
- Configure a tag/descriptor factory, e.g. `factory: "Example::H"`.
- Haml transforms generate Ruby component classes exported as `Default`.
- Haml importing Haml should return the component class.
- `%Details(...)` should compile to a factory call using the imported `Details` class as the tag/component.

Companion files:

- `page.haml` automatically imports/watches `page.css` as `Styles`.
- `page.haml` watches `page.intl.*.toml` and exposes translations.
- Companion file add/update/remove should invalidate the Haml owner even when the companion was not in the dependency graph before.

Source maps:

- Haml generated Ruby uses `SourceMapMark` comments.
- Backtrace rewriting should map runtime errors back to Haml source paths and lines.
- Parse errors should show source context with a highlighted line and no noisy Ruby backtrace.

Haml script behavior:

- `=` prints the result.
- `-` is silent and should not leak values into output.
- Silent blocks are wrapped so they evaluate to `nil`.
- `= if ...` style printed blocks need block handling and should render their body.
- Whitespace insertion around Haml tags should use parser node flags, especially `nuke_inner_whitespace` and `nuke_outer_whitespace`. Avoid passing source lines around to rediscover `<`/`>` markers.

HTML factory shape used by the example:

```ruby
def self.[](tag, *children, **props)
end
```

Avoid reverting this to `def self.[](tag, *children)`.

## CSS Rules

CSS is scoped through `mayu-css`.

Important conventions:

- CSS imports from Ruby/Haml return class-name maps.
- CSS imports from CSS return paths to transformed CSS assets.
- Tag selectors are represented with symbol keys prefixed by `__`, e.g. `:__figure`.
- Class names use normal symbol keys, e.g. `:image`.
- Haml should automatically apply scoped tag classes to matching tags.
- Haml classes like `%img.image` should apply `:image`.
- Use a `clsx`-style class join helper rather than hand-concatenating strings.

CSS assets:

- `context.assets_for_module(...)` accepts a single module or an array of route module roots.
- `context.asset_references_for_module(...)` returns references with graph `index` plus `asset`.
- Example stylesheet links include `data-index` from the route-scoped graph traversal.
- Use route-scoped modules for CSS lookup, not all graph assets.
- Root/layout CSS should appear before page/component CSS by traversal order.

External CSS imports can be plugin-owned. Google Fonts imports are handled by `GoogleFontsPlugin`, which downloads the Google CSS during collection, rewrites font URLs to local emitted assets, and keeps font bytes as generated assets.

When styling the example app, prefer scoped tag selectors over class names when each component has only one of that element. Use classes only when multiple same-tag elements need different styling.

## Asset Rules

Plugins emit `Klenod::Build::Asset`.

Stable identifiers:

- `logical_name`: source-root-relative path without import query.
- `output_path`: content-hashed public path.

Generated images:

- Image imports return image metadata objects with `src`, dimensions, and variants.
- `image.srcset` exists; avoid rebuilding `variants.map { "#{it.src} #{it.descriptor}" }.join(", ")` in templates.
- Default `sizes` can come from the image object/config instead of every component manually setting it.
- Overlapping variants from different imports should dedupe. Example: `?width=320,640` and `?width=640` should generate `640` once.
- Generated bytes can be deferred; call `asset.wait` or `context.asset_bytes(...)` before serving if needed.
- Build mode should drain generated assets before writing output.

Generated asset work is classified with `queue_kind`, defaulting to `:cpu`. Image variants should explicitly use `queue_kind: :cpu`. IO-bound generated assets, such as downloaded Google font files, should use `queue_kind: :io`. `AssetGenerationQueue` has separate CPU and IO semaphores so downloads can overlap with image resizing without either category becoming unbounded.

Development asset serving is framework responsibility. Klenod provides assets and optional helpers; it should not become a full dev asset server.

## Example Web App Notes

The example app is both a smoke test and documentation. Keep it realistic but not too clever.

Current framework pieces live under `example/web/lib/framework.rb` and `example/web/lib/framework/`:

- `Example::Request`
- `Example::Response`
- encrypted cookie-backed sessions using `rbnacl`
- `Example::Context` stored in `Thread.current`
- `Example::Component`
- `Example::Form`
- `Example::H`
- `Example::Route`

The framework is intentionally minimal; avoid moving too much framework behavior into Klenod core.

Pages are under `example/web/src/pages`.

Important routes:

- `/demo/hybrid`: page + `route.rb` hybrid behavior.
- `/demo/dashboard`: layouts and parallel routes.
- `/demo/blog`: TOML data imports.
- `/demo/assets`: image variants.
- `/demo/not-found-error`: not-found rendering that itself raises and falls back to an error view.
- `/demo/forms`: sessions, forms, CSRF, redirects.
- `/demo/routing`: router metadata.

The example server uses `async-http`. It logs requests and update events with ANSI formatting, dims asset requests, and prints formatted render errors to the console. Update-time parse errors and request-time errors share a short recent-error cache so browser follow-up requests do not flood the console, but later failed requests still log normally.

## Testing Tricks

Prefer focused tests while iterating, then broaden:

```sh
bundle exec ruby lib/klenod/build/plugins/router_plugin.test.rb
bundle exec ruby example/web/example.test.rb
```

Use `NO_COLOR=1` when asserting CLI output from `example/web/bin/routes`.

Use `HeaderRequest` in `example/web/example.test.rb` to test `Accept` behavior.

Use `BodyRequest` and `ReadableBody` in example tests for forms.

For route handler line numbers, `example/web/bin/routes` scans `def GET`, `def POST`, etc. Keep route handler examples simple enough for that scanner unless the scanner is being improved.

## Code Style And Editing

- Use modern Ruby features where they make code clearer: `Data.define`, numbered block params where Standard accepts them, keyword args, pattern-like small value objects.
- Use `Data.define` for immutable values. Use regular classes when mutation or behavior-heavy objects are needed.
- Preserve runtime/build/dev boundaries before adding convenience APIs.
- Keep server/framework behavior out of Klenod core unless it is genuinely framework-agnostic.
- Use `apply_patch` for manual edits.
- Do not run destructive git commands.
- Be careful with staged user changes. Check `git status --short` before and after.

## Known Follow-Ups

From `PLAN.md` and recent work:

- Revisit route utility ordering and visualization so displayed routes follow actual router match priority.
- Continue scheme-aware imports for future `plugin:` and `gem:` modules.
- Keep replacing ad hoc app/virtual checks with scheme-aware helpers where useful.
- Add `klenod dev` only after API shape is clearer; frameworks may own dev commands.
- Eventually revisit async rendering/context propagation. Current example context uses `Thread.current` and assumes synchronous rendering.
