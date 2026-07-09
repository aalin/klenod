# Klenod Example

This example exercises the current module graph, plugin pipeline, emitted assets, and watch-mode update events.

Run it from the repository root:

```sh
bundle exec ruby example/run.rb
bundle exec ruby example/build_and_load.rb
bundle exec ruby example/watch.rb
bundle exec ruby example/server.rb
```

`run.rb` loads `src/pages/server.rb`, which imports `virtual:router`, matches `/`, renders `src/pages/page.haml`, and wraps it in `src/pages/layout.haml`.

`build_and_load.rb` writes `example/dist/klenod.bundle`, reloads it through the runtime API, and evaluates the entrypoint without using the build graph.

`watch.rb` keeps the process running and prints invalidation events when loaded files under `example/src` change.

`server.rb` starts a small `async-http` server on `http://localhost:9292`. It watches the source tree, matches each request through the router plugin, and serves emitted CSS/image assets from the build context.

`watch.rb` and `server.rb` can also mirror emitted assets to disk:

```sh
ASSETS_DIR=example/tmp/public bundle exec ruby example/watch.rb
ASSETS_DIR=example/tmp/public bundle exec ruby example/server.rb
```

When `ASSETS_DIR` is set, the examples write the current asset manifest once and then apply `event.asset_updates` after each successful graph update.

The server entry imports the virtual router and an image with query-driven variants:

```ruby
Router = import("virtual:router")
SmokedFish = import("./smoked-fish.png?width=320,640&format=png")
```

`Router::Default.match(path).page` returns the matched component class. The server entry wraps the rendered page through `match.layouts`, passing the current HTML as `children: [inner]` and an empty `slots: {}` hash. The nested route `src/pages/blog/[slug]/page.haml` demonstrates dynamic params at `/blog/hello`.

`framework.rb` defines the example `Example::H` factory used by the Haml plugin. `src/pages/page.haml` renders through that factory, imports `src/components/Figure.haml`, and automatically imports its companion `src/pages/page.css` as `Styles`.

The example uses explicit extensions for page imports. If both `page.rb` and `page.haml` exist, an extensionless import like `import("./page")` is ambiguous and Klenod asks for `import("./page.haml")` or `import("./page.rb")`.
