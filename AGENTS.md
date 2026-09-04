# AGENTS.md

Guidance for future agent sessions working on Klenod.

## Project Shape

Klenod is an experimental Ruby module bundler inspired by JavaScript bundlers and filesystem-based web frameworks.

Keep these boundaries intact:

- `gems/klenod-runtime/lib/klenod/runtime/`: production bundle loading, module evaluation, source maps, assets, and backtrace rewriting. It must not require build plugins or heavyweight build dependencies.
- `gems/klenod-build/lib/klenod/build/`: graph collection, resolving, transforms, plugins, invalidation, asset generation, and bundle writing.
- `gems/klenod-test/`: framework-independent test discovery, dependency selection, watch runs, and worker isolation. It depends on `klenod-build` but not on a test framework.
- `gems/klenod-rack/lib/klenod/rack/`: Rack-compatible serving helpers, not application or framework policy.
- `gems/klenod-plugin-css/`: the native CSS plugin and its Ruby integration.
- `gems/klenod-plugin-javascript/`: the native JavaScript/TypeScript plugin and its Ruby integration.
- `gems/klenod/`: the compatibility meta gem.
- `example/web/`: the framework-style example, executable documentation, and web integration coverage.
- `example/standalone/`: executable bundles and non-web data imports.
- `example/performance/`: generated larger graphs used for performance smoke coverage.

Read these before broad architecture work:

- `README.md`
- `ARCHITECTURE.md`
- `docs/graph-and-plugin-phases.md`
- `example/web/README.md`

Prefer those files and the current implementation over historical assumptions in commit messages or old examples.

## Development Workflow

Tests are co-located:

- Test files use `*.test.rb`.
- Fixtures live in a sibling `__test__/` directory near the implementation.
- Haml transform golden tests live under `gems/klenod-build/lib/klenod/build/plugins/__test__/haml`.

Useful suites:

```sh
bundle exec rake test:runtime
bundle exec rake test:build
bundle exec rake test:rack
bundle exec rake test:css
bundle exec rake test:javascript
bundle exec rake test:gems
bundle exec rake test:examples
bundle exec rake test:web
```

Useful focused commands:

```sh
bundle exec ruby gems/klenod-build/lib/klenod/build/context.test.rb
bundle exec ruby gems/klenod-build/lib/klenod/build/plugins/router_plugin.test.rb
bundle exec ruby gems/klenod-build/lib/klenod/build/plugins/haml.test.rb
bundle exec ruby gems/klenod-runtime/lib/klenod/runtime/mod.test.rb
bundle exec ruby example/standalone/example.test.rb
```

Run Standard on changed Ruby files:

```sh
RUBOCOP_CACHE_ROOT=/private/tmp/rubocop_cache bundle exec standardrb path/to/file.rb ...
```

The cache root matters in sandboxed environments. Plain `standardrb` may try to write under `~/.cache` and fail.

Example web commands:

```sh
example/web/bin/build
example/web/bin/dev
example/web/bin/routes
example/web/bin/server
```

## Documentation Is Part Of The Example

User-facing documentation lives under `example/web/src/routes/docs`. It is a primary product surface, not incidental demo content.

Important documentation areas include:

- `docs/getting-started`, `docs/core-concepts`, and `docs/configuration`
- `docs/module-graph`, `docs/development`, and `docs/build-runtime`
- `docs/haml-components`, `docs/templates`, `docs/assets`, `docs/data`, and `docs/routing`
- `docs/plugins` and the plugin reference pages under `docs/plugins/*`

When changing a plugin, configuration option, import behavior, generated output, routing behavior, asset behavior, or another public API:

- Update the relevant page under `example/web/src/routes/docs` in the same change.
- For plugin changes, check `example/web/src/routes/docs/plugins/<Plugin>/+page.haml` first, then update related guide/configuration pages when the behavior is also explained there.
- Keep `README.md`, `ARCHITECTURE.md`, plugin READMEs, and the in-app documentation consistent with each other.
- If adding a documentation page, add it to `example/web/src/routes/docs/+layout.haml` and link it from the appropriate overview page.
- Parse or build changed Haml documentation and run `bundle exec rake test:web` when dependencies are available.

Documentation pages also render as `text/markdown` through content negotiation. Write semantic component trees and Markdown filters that remain useful without browser layouts.

Routes under `/demo` are exploratory examples and may be removed. Do not treat them as the canonical explanation of a feature or add new guidance that depends on a demo route when a documentation page is the better home.

## Core Architecture Rules

### Collection And Evaluation

Graph collection and module evaluation are separate:

- Collected means source was loaded and transformed, dependencies were recorded, assets were emitted, and a `ModuleRecord` exists.
- Evaluated means a `Klenod::Runtime::Mod` was instantiated and the module's Ruby top-level code ran.
- `context.entry(...)` and `context.collect(...)` collect without evaluating application code.
- `entry.exports`, `entry.call(...)`, `context.exports(...)`, and `context.evaluate(...)` evaluate on demand.
- Build mode serializes collected records without evaluating application modules.

Development invalidation must preserve that split:

- Store a failed `ModuleRecord` and its original error when a changed module cannot reload.
- Do not reevaluate dependents during the same failed update.
- Evict evaluated dependent mods so later demand raises the stored error instead of serving stale exports.
- Keep unrelated modules on the previous good graph.
- Async collection work should return failures to the parent path; expected build errors must not leak as unhandled `Async::Task` exceptions.

### Plugin Phases

- `resolve`, `load`, `transform`, and `finalize` are collection-time hooks.
- `import_value` supplies live development/evaluation values.
- `runtime_import_value` supplies serializable bundle values or runtime instructions.
- Collection and runtime serialization must not depend on evaluated application exports.
- Plugin `load` and `transform` hooks can overlap across sibling dependencies; avoid unguarded shared mutable state.

### Module IDs And Imports

- Module IDs are canonical URI-like IDs such as `app:/components/Card.haml`, `virtual:/router.rb`, and `gem://klenod-ui/Button.haml`.
- `import("./foo")` and `import("foo")` resolve relative to the importer.
- `import("/foo")` resolves from the current scheme root.
- Use `app:/foo` when a non-app scheme needs the configured application source root.
- Plugins must resolve non-app schemes before filesystem resolution.
- `lazy_import("...")` records a dependency and defers loading/evaluation until called.
- `import_glob("...")` returns deterministic matches and supports lazy values.
- Eager import cycles should report the cycle chain. Lazy imports are the escape hatch.

## Runtime Boundary

- Production bundles must load with `klenod-runtime` alone.
- Do not serialize plugin objects that require build dependencies.
- Runtime-owned values belong under `Klenod::Runtime` or in serializable virtual-module data.
- Image runtime values must not require RMagick or `image_size`.
- Executable bundles prepend Ruby source and store binary marshal data after `__END__`; they are not intended to be editor-friendly.

## Haml And Markdown

`HamlPlugin` and `MarkdownPlugin` are adapters that generate component-shaped Ruby output. Rendering semantics stay in the configured component base class and factory.

Haml configuration includes:

- `component_base_class`, the superclass for generated components.
- `factory`, the receiver for generated element/component calls.
- `component_children`, either `:eager` (the default positional arguments) or `:lazy` (a child-producing block).
- `variables`, which can map Haml global, class, and instance variables to indexed receiver expressions.

The example web app uses `component_children: :lazy` for conditional children, slots, and context boundaries. Its factory accepts both positional children and an optional block:

```ruby
def self.[](tag, *children, **props, &lazy_children)
end
```

Other Haml invariants:

- Generated Haml modules export their component class as `Default`.
- Importing Haml from Ruby or Haml returns that component class.
- `%Details(...)` passes the imported `Details` class as the factory tag.
- `Component.css` and `Component.intl.*.toml` companions are watched; add/update/remove invalidates the Haml owner.
- Generated Ruby uses `SourceMapMark` comments. Runtime errors map back to Haml, while parse errors show source context directly.
- `=` prints, `-` is silent, silent blocks evaluate to `nil`, and printed control-flow blocks render their bodies.
- Whitespace handling should use parser flags such as `nuke_inner_whitespace` and `nuke_outer_whitespace`, not rediscovered source markers.
- Markdown files and Haml `:markdown` filters share the Markdown component-map behavior.

## Router

Routing is optional and owned by `RouterPlugin`; core Klenod must not assume a web framework.

- Route files include pages, handlers, layouts, error views, and not-found views.
- Supported segments include dynamic, catch-all, optional catch-all, route groups, parallel routes, and intercepted routes.
- Generated router modules use lazy imports so development does not evaluate every page at startup.
- `Router::Default.match(path)` exposes page, handler, layouts, slots, params, and route metadata.
- Missing pages resolve the closest not-found module. Rendering failures use the closest error module, with layouts selected relative to the special view being rendered.
- HTTP content negotiation and hybrid page/handler dispatch are example-server policy, not router policy.

`example/web/bin/routes` prints the discovered route table and tree. Use `NO_COLOR=1` for output assertions.

## CSS And Assets

- CSS imports from Ruby/Haml return scoped class-name maps; CSS importing CSS receives transformed asset paths.
- Class selectors use normal symbol keys such as `:button`; tag selectors use `__`-prefixed keys such as `:__figure`.
- Haml applies scoped tag and explicit class mappings. Centralize class joining in the `clsx`-style helper.
- Prefer native CSS nesting to group related selectors under their component or layout block. Preserve the intended selector semantics and use `&` when referring to the nesting selector.
- Route-scoped asset lookup should use `assets_for_module(...)` or `asset_references_for_module(...)`, not every graph asset.
- Root/layout CSS should precede page/component CSS by graph traversal order.
- Assets have a stable `logical_name` and a content-hashed `output_path`.
- Overlapping image variants must deduplicate generated work. Use `image.srcset` and configured default sizes instead of rebuilding them in templates.
- Generated assets default to `queue_kind: :cpu`; IO-bound work such as font downloads uses `:io`.
- Build mode drains generated assets before writing output.
- Development asset serving remains consumer/framework responsibility.

## Example Web App

The web example is both integration coverage and documentation. Keep it realistic, small, and readable.

Framework code lives under `example/web/lib/framework.rb` and `example/web/lib/framework/`. It includes request/response objects, fiber-local context, components, the element factory, forms, sessions, routing glue, HTML rendering, and Markdown rendering.

Keep application policy in the example unless an abstraction is genuinely framework-neutral. In particular, request representation negotiation, hybrid route dispatch, session/form behavior, error rendering, and development asset serving do not belong in Klenod core.

The documentation routes are the durable examples. Prefer extending them over adding dependencies on `/demo` pages.

When changing a Haml component, page, or layout under `example/web/src`, treat
its companion files as part of the same change:

- Companion files use the same directory and basename as the Haml file: `Component.haml` has `Component.css` and `Component.intl.*.toml`, `+page.haml` has `+page.css` and `+page.intl.*.toml`, and `+layout.haml` has `+layout.css` and `+layout.intl.*.toml`.
- Always inspect and update the sibling CSS file when markup changes. Check selectors that depend on element type, nesting, sibling position, or pseudo-classes such as `:first-child` and `:last-child`, not only class names.
- Always inspect every sibling `.intl.*.toml` file when translated content changes. Add, rename, or remove keys consistently across all locales so the Haml and translation companions do not drift.

## Testing Notes

- Prefer focused tests while iterating, then run the relevant package suite.
- Use `HeaderRequest` in `example/web/example.test.rb` for `Accept` and representation behavior.
- Use `BodyRequest` and `ReadableBody` for form/request bodies.
- Keep simple `def GET`, `def POST`, etc. declarations when route CLI line-number scanning matters.
- Update Haml golden fixtures only when the generated output change is intentional.
- Native CSS or JavaScript changes should run their package-specific suites in addition to Ruby integration tests.

## Code Style And Editing

- Use modern Ruby features where they improve clarity: `Data.define`, keyword arguments, and numbered block parameters where Standard accepts them.
- Use `Data.define` for immutable values and regular classes for mutable or behavior-heavy objects.
- Preserve runtime/build/development boundaries before adding convenience APIs.
- Keep framework policy out of Klenod core.
- Use `apply_patch` for manual edits.
- Do not run destructive git commands.
- Check `git status --short` before and after; preserve unrelated and staged user changes.
- After completing a coherent change that should be committed, suggest a short, simple, and clear commit message in the repository's imperative style.
