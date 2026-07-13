# Klenod Web Example

This example exercises the current module graph, plugin pipeline, emitted assets, and watch-mode update events.

Run it from the repository root:

```sh
bundle exec ruby example/web/run.rb
bundle exec ruby example/web/build.rb
bundle exec ruby example/web/load.rb
bundle exec ruby example/web/watch.rb
bundle exec ruby example/web/routes.rb
bundle exec ruby example/web/server.rb
```

`run.rb` loads `src/pages/server.rb`, which imports `virtual:router`, matches `/`, renders `src/pages/page.haml`, and wraps it in `src/pages/layout.haml`.

`build.rb` writes `example/web/dist/klenod.bundle` and `example/web/dist/public`, printing the collected module count, emitted assets, generated assets, and written files. `load.rb` reloads that bundle through the runtime API and evaluates the entrypoint without using the build graph. It passes `source_root:` when loading the bundle so `__FILE__` and raw Ruby backtraces point at the runtime source root:

```ruby
bundle = Klenod::Runtime.load_bundle("example/web/dist/klenod.bundle", source_root: "/app/src")
```

The same build can be run through the CLI using the example Ruby config:

```sh
cd example/web
bundle exec ../../exe/klenod build
```

`watch.rb` keeps the process running and prints invalidation events when loaded files under `example/web/src` change.

`routes.rb` prints a Rails-style route table with the HTTP method, server path, route type, and source file for each discovered `page.haml` and `route.rb`.

`server.rb` starts a small `async-http` server on `http://localhost:9292`. It watches the source tree, matches each request through the router plugin, and serves emitted CSS/image assets from the build context.

`watch.rb` and `server.rb` can also mirror emitted assets to disk:

```sh
ASSETS_DIR=example/web/tmp/public bundle exec ruby example/web/watch.rb
ASSETS_DIR=example/web/tmp/public bundle exec ruby example/web/server.rb
```

When `ASSETS_DIR` is set, the examples write the current asset manifest once and then apply `event.asset_updates` after each successful graph update.

The server entry imports the virtual router:

```ruby
Router = import("virtual:router")
```

Pages import their own assets. For example, `src/pages/page.haml` imports an image with query-driven variants.

`Router::Default.match(path).page` returns the matched component class. `Router::Default.match(path).handler` returns a matched `route.rb` handler class. The server entry wraps rendered pages through `match.layouts`, passing the current HTML as `children: [inner]`, renders named parallel routes from `match.slots`, and dispatches route handlers through the example `Example::Route` base class. The nested route `src/pages/demo/blog/[slug]/page.haml` demonstrates dynamic params at `/demo/blog/graph`.

The example includes a small route gallery:

- `/demo/docs/guides/routing` demonstrates catch-all params.
- `/demo/shop` and `/demo/shop/sale/red` demonstrate optional catch-all params.
- `/about` demonstrates a route group.
- `/api/status` demonstrates a `route.rb` handler that returns JSON.
- `/demo/hybrid` demonstrates a route directory with both `page.haml` and `route.rb`; browser requests render HTML, while API-style requests use the handler.
- `/demo/dashboard` demonstrates a small logistics dashboard with `@sidebar` and `@modal` parallel slots. `/demo/dashboard/settings` renders `dashboard/settings/page.haml` as the primary route and matching slot pages into `dashboard/layout.haml`.
- `/feed/photo`, `/profile`, and `/login` demonstrate intercepted route segment metadata.
- `/demo/routing` reads `Router::Default.tree` and displays structural route metadata.

`framework.rb` defines the example `Example::H` factory used by the Haml plugin. `src/pages/page.haml` renders through that factory, imports `src/components/Figure.haml`, and automatically imports its companion `src/pages/page.css` as `Styles`.

The example uses explicit extensions for page imports. If both `page.rb` and `page.haml` exist, an extensionless import like `import("./page")` is ambiguous and Klenod asks for `import("./page.haml")` or `import("./page.rb")`. A `route.rb` handler can live in the same directory as a page. For hybrid routes, browser-style `GET`, `POST`, and `HEAD` requests that prefer `text/html` render the page; API-style requests and `PUT`, `PATCH`, `DELETE`, and `OPTIONS` requests use `route.rb`.
