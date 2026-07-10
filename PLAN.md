# Klenod Plan

Klenod is a Ruby module bundler inspired by Vite, Rollup, Parcel, and Webpack. It loads source files through a plugin pipeline, builds a dependency graph, evaluates modules as marshalable `Klenod::Runtime::Mod` instances, and can serialize a runtime-only bundle for production.

## Current Milestones

- [x] Create separate architecture boundaries:
  - [x] `lib/klenod/build/` for graph construction, resolving, bundling, and plugins.
  - [x] `lib/klenod/dev/` for watch mode and reload events.
  - [x] `lib/klenod/runtime/` for production-safe loading and bundle hydration.
- [x] Add co-located `*.test.rb` tests and update Rake discovery.
- [x] Implement runtime `Mod` with stable generated constants.
- [x] Implement source-map marker parsing and backtrace rewriting foundation.
- [x] Implement Parcel-style unresolved `Dependency` objects.
- [x] Implement resolver support for relative imports and source-root absolute imports.
- [x] Implement Ruby plugin support for literal `import("...")`.
- [x] Implement `lazy_import("...")` with deferred dev loading and lazy bundle hydration.
- [x] Implement runtime bundle loading with `Klenod::Runtime.load_bundle`.
- [x] Implement graph invalidation and dev watcher update events.
- [x] Add initial async loading for sibling dependency modules.
- [x] Share in-flight async module loads across concurrent dependency branches.
- [x] Detect eager import cycles and report the module chain.
- [x] Split graph module loading into explicit read, transform, dependency, finalize, and evaluation phases.
- [x] Implement CSS plugin with class-map import values and content-hashed asset emission.
- [x] Add example app for graph loading, bundle loading, and watch mode.

## Next Milestone: Haml Companion Dependencies

- [x] Add a `WatchedPattern` or `DependencyPattern` value object:
  - [x] Store importer module id.
  - [x] Store source-root-relative glob.
  - [x] Store pattern kind, such as `:companion_style` or `:companion_intl`.
- [x] Extend `ModuleRecord` with watched patterns.
- [x] Extend graph invalidation:
  - [x] Match changed files against loaded module ids.
  - [x] Match added, changed, and removed files against watched patterns.
  - [x] Reload or reevaluate the owning module when a watched pattern matches.
- [x] Add Haml companion discovery:
  - [x] For `page.haml`, implicitly watch and import `page.css`.
  - [x] For `page.haml`, implicitly watch `page.intl.*.toml`.
  - [x] Return `{}` when optional companion files do not exist.
- [x] Add tests for companion invalidation:
  - [x] Adding `page.css` after `page.haml` is loaded updates the component.
  - [x] Editing `page.css` updates the component.
  - [x] Removing `page.css` updates the component back to empty styles.
  - [x] Adding, editing, and removing `page.intl.en-US.toml` invalidates `page.haml`.

## Haml Support

- [x] Keep Haml rendering logic outside Klenod.
- [x] Define the Haml plugin as an adapter around an external Haml component transformer.
- [x] Add Haml plugin configuration:
  - [x] Component base class constant path, such as `Mayu::Component::Base`.
  - [x] Factory constant path, such as `Mayu::Descriptors::H`.
- [x] Generate Ruby source that evaluates into a component class inside `Klenod::Runtime::Mod`.
- [x] Inject `Styles` from the companion CSS import.
- [x] Inject `Translations` from companion TOML files.
- [x] Preserve source-map markers from Haml source to generated Ruby.
- [x] Export the generated component class as `Default`.
- [x] Add Haml examples under `example/web/src/pages/`.
- [x] Add backtrace tests for errors raised from generated Haml Ruby.

## Translation Files

- [x] Choose and add a TOML parser dependency.
- [x] Add a TOML or intl plugin.
- [x] Parse files like `page.intl.en-US.toml`.
- [x] Expose translations grouped by locale.
- [x] Serialize translations into runtime bundles without build dependencies.
- [x] Add tests for malformed TOML and locale extraction.

## Asset And CSS Follow-Ups

- [x] Decide and document asset output conventions.
- [x] Add a public asset manifest API.
- [x] Write emitted asset files during build.
- [x] Keep runtime asset specs metadata-only.
- [x] Add CSS invalidation tests for class-map changes.
- [x] Improve CSS import behavior when CSS imports CSS.
- [x] Add image size detection with `image_size`.
- [x] Add RMagick-backed image variants.
- [x] Support import-query image variants with cross-import dedupe.
- [x] Add generated asset objects that can defer variant bytes until `wait` or `bytes`.
- [x] Add a build-owned generated asset queue with configurable concurrency.
- [x] Cover dev cleanup for stale and failed generated assets.

## Dev Server And Runtime

- [x] Add optional Rack integration for serving emitted assets:
  - [x] Provide a small Rack endpoint/middleware that serves `context.asset(path).bytes`.
  - [x] Support runtime bundles by serving files already written under an assets directory.
  - [x] Keep framework-specific HTTP/server behavior outside core build/runtime.
- [x] Add a stable event payload for hot reload consumers.
- [x] Add runtime API for reading bundle assets.
- [x] Add runtime-only boundary tests to ensure runtime does not require build or plugin dependencies.
- [x] Add public exports helpers and reachable module asset lookup.
- [x] Add direct-vs-recursive module asset lookup.
- [x] Add update application helper for refreshing exports and mirroring assets.
- [x] Add loaded module handles for entry exports and assets.
- [x] Return loaded entry handles from applied updates.
- [x] Add callable entry handles and mirrored asset byte reads.
- [x] Add applied update helpers for failures and mirrored asset changes.
- [x] Add executable Ruby bundle output for non-framework entrypoints.
- [ ] Split graph collection from module evaluation:
  - [x] In build mode, transform, resolve, and serialize modules without evaluating app module code.
  - [x] In development mode, avoid evaluating entry modules until exports or calls are requested.
  - [x] Add or document a public collection API distinct from eager evaluation, such as `context.collect`.
  - [x] Decide whether `context.load` remains eager or gets renamed to make evaluation explicit.
  - [x] Track module evaluation state explicitly, or consistently derive it from `graph.mods`.
  - [x] Make invalidation preserve collected-but-not-evaluated modules without evaluating them.
  - [x] Make `apply_update` avoid forcing entry evaluation unless the entry was already evaluated or the caller requests exports.
  - [ ] Keep plugin build-time work explicit through plugin hooks instead of top-level app side effects.
  - [ ] Add tests proving build serialization does not call dev-only `import_value` hooks.
  - [ ] Document plugin hook phases: `transform`/`finalize`, dev `import_value`, and runtime `runtime_import_value`.
- [ ] Add CLI commands after the Ruby API stabilizes:
  - [x] `klenod build`
  - [ ] `klenod dev`
  - [x] Keep CLI code separate from `klenod/runtime` so it can become a separate gem.
  - [x] Load nearest `klenod.config.rb` and run from the config directory.
  - [ ] Add a ratatat-backed TUI after the command API settles.

## Module Identity And Import Schemes

- [x] Keep app source modules as source-root-relative module ids by default.
- [x] Reserve module id schemes without migrating graph keys yet:
  - [x] `app` for source-root files, inferred when no explicit scheme is present.
  - [x] `virtual` for generated modules such as `virtual:router`.
  - [ ] Future `gem` or `plugin` schemes for imports resolved outside the app source root.
- [x] Add `ModuleId#scheme` and `ModuleId#bare_path` helpers.
- [ ] Replace ad hoc virtual/app checks with scheme-aware helpers where useful.
- [ ] Design external plugin/package imports after the current app-root `/foo` imports settle:
  - [ ] Reserve `plugin:` and `gem:` import specifiers for modules outside `source_dir`.
  - [ ] Let resolver plugins handle non-app schemes before the filesystem resolver runs.
  - [ ] Raise a clear `ResolveError` for unknown schemes that no plugin resolves.
  - [ ] Add tests with a small fake resolver plugin for `plugin:demo`.
  - [ ] Keep `import("/foo")` as the only app-root import syntax for now.

## Routing And App Structure

- [x] Move NextJS-style page discovery into an optional router plugin.
- [x] Build a low-level route manifest foundation in the router plugin:
  - [x] Parse route segments without committing to router rendering policy.
  - [x] Preserve dynamic segments such as `[id]`.
  - [x] Preserve catch-all segments such as `[...slug]`.
  - [x] Preserve optional catch-all segments such as `[[...slug]]`.
  - [x] Preserve route groups such as `(marketing)` without adding URL path parts.
  - [x] Preserve parallel route slots such as `@modal`.
  - [x] Preserve layout ancestry as module ids without loading or composing layouts.
  - [x] Expose route param metadata without implementing request matching.
  - [x] Expose a route manifest with route lookup and build entrypoints.
- [x] Add a NextJS-inspired router plugin:
  - [x] Resolve and load a `virtual:router` module.
  - [x] In development, keep routing dynamic so startup does not load every page.
  - [x] Load only the matched page module on demand.
  - [x] In build mode, eager-import discovered pages and layouts into the bundle graph.
  - [x] Prefer static routes over dynamic, catch-all, and optional catch-all routes.
- [x] Add a structural route tree API for layout composition.
- [x] Represent real parallel route slots in the route tree.
- [x] Parse intercepted route segments such as `(.)`, `(..)`, and `(...)`.
- [x] Add structural `layout.haml` discovery.
- [x] Add structural path param metadata.
- [x] Decide whether routing belongs in a router plugin.
- [x] Add structural route manifest generation.
- [x] Resolve router build-mode cycles:
  - [x] Keep generated route page/layout references lazy in the router module.
  - [x] Ensure build bundles still include every discovered page/layout module.
  - [x] Add a regression where a page imports `virtual:router` and the router bundle still builds.

## Testing And Examples

- [x] Use co-located `*.test.rb` files.
- [x] Use `__test__/` directories next to test files for fixtures when needed.
- [x] Add fixture-heavy examples for CSS, Haml, assets, and intl files.
- [x] Add integration tests for build bundle round trips.
- [x] Add watch-mode tests for added and removed files.
- [x] Keep `example/` runnable as a smoke test for major features.
- [x] Add a standalone non-web example for data imports and executable bundles.
