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
- [x] Implement runtime bundle loading with `Klenod::Runtime.load_bundle`.
- [x] Implement graph invalidation and dev watcher update events.
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
- [x] Add Haml examples under `example/src/pages/`.
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

## Dev Server And Runtime

- [ ] Add a development server or Rack integration for serving emitted assets.
- [x] Add a stable event payload for hot reload consumers.
- [x] Add runtime API for reading bundle assets.
- [x] Add runtime-only boundary tests to ensure runtime does not require build or plugin dependencies.
- [ ] Add CLI commands after the Ruby API stabilizes:
  - [ ] `klenod dev`
  - [ ] `klenod build`

## Routing And App Structure

- [ ] Add NextJS-style page discovery under `src/pages/`.
- [ ] Add `layout.haml` support.
- [ ] Add path params.
- [ ] Decide whether routing belongs in a router plugin.
- [ ] Add route manifest generation.

## Testing And Examples

- [x] Use co-located `*.test.rb` files.
- [x] Use `__test__/` directories next to test files for fixtures when needed.
- [ ] Add fixture-heavy examples for CSS, Haml, assets, and intl files.
- [ ] Add integration tests for build bundle round trips.
- [x] Add watch-mode tests for added and removed files.
- [ ] Keep `example/` runnable as a smoke test for major features.
