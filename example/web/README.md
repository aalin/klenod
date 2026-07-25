# Klenod Web Example

This example exercises the current module graph, plugin pipeline, emitted assets, and watch-mode update events.

Run it from the repository root:

```sh
example/web/bin/build
example/web/bin/dev
example/web/bin/routes
example/web/bin/server
```

`bin/build` writes `example/web/dist/klenod.bundle` and `example/web/dist/public`, printing the collected module count, emitted assets, generated assets, and written files. `bin/server` starts a production-style `async-http` server from that built bundle without using the build graph. It passes `source_root:` when loading the bundle so `__FILE__` and raw Ruby backtraces point at the runtime source root:

```ruby
bundle = Klenod::Runtime.load_bundle("example/web/dist/klenod.bundle", source_root: "/app/src")
```

The same build can be run through the CLI using the example Ruby config:

```sh
cd example/web
bundle exec klenod build
```

Export the built bundle graph as Graphviz DOT and render it as SVG:

```sh
bundle exec klenod graph dist/klenod.bundle > graph.dot
dot -Tsvg graph.dot > graph.svg
```

To profile a build with Vernier:

```sh
cd example/web
bundle exec vernier run -- bin/build
```

Vernier writes a profile file in the current directory. Use `bundle exec vernier view -- <profile>` for a terminal summary, or open the generated profile in a compatible profile viewer.

`bin/routes` prints a Rails-style route table with the HTTP method, server path, route type, and source file for each discovered `+page.haml` and `+route.rb`.

`bin/dev` starts the development `async-http` server on `http://localhost:9292`. It watches the source tree, matches each request through the router plugin, serves emitted CSS/image assets from the build context, and renders detailed development exception pages.

`bin/server` starts the production server on `http://localhost:9292` from the bundle and assets written by `bin/build`. It logs exceptions server-side, but returns a generic 500 response instead of rendering development error details.

`bin/dev` can also mirror emitted assets to disk:

```sh
ASSETS_DIR=example/web/tmp/public example/web/bin/dev
```

When `ASSETS_DIR` is set, the examples write the current asset manifest once and then apply `event.asset_updates` after each successful graph update.

The server entry imports the virtual router:

```ruby
Router = import("virtual:router")
```

Pages import their own assets. For example, `src/routes/+page.haml` imports an image with query-driven variants.

`Router::Default.match(path).page` returns the matched component class. `Router::Default.match(path).handler` returns a matched `+route.rb` handler class. The server entry wraps rendered pages through `match.layouts`, passing the current HTML as `children: [inner]`, renders named parallel routes from `match.slots`, and dispatches route handlers through the example `Example::Route` base class. The nested route `src/routes/demo/blog/[slug]/+page.haml` demonstrates dynamic params at `/demo/blog/graph`.

The example includes a small route gallery:

- `/demo/docs/guides/routing` demonstrates catch-all params.
- `/demo/shop` and `/demo/shop/sale/red` demonstrate optional catch-all params.
- `/about` demonstrates a route group.
- `/api/status` demonstrates a `+route.rb` handler that returns JSON.
- `/demo/hybrid` demonstrates a route directory with both `+page.haml` and `+route.rb`; browser requests render HTML, while API-style requests use the handler.
- `/demo/dashboard` demonstrates a small logistics dashboard with `@sidebar` and `@modal` parallel slots. `/demo/dashboard/settings` renders `dashboard/settings/+page.haml` as the primary route and matching slot pages into `dashboard/+layout.haml`.
- `/feed/photo`, `/profile`, and `/login` demonstrate intercepted route segment metadata.
- `/demo/routing` reads `Router::Default.tree` and displays structural route metadata.

`framework.rb` defines the example `Example::H` factory used by the Haml plugin. `src/routes/+page.haml` renders through that factory, imports `src/components/Figure.haml`, and automatically imports its companion `src/routes/+page.css` as `Styles`.

The example uses explicit extensions for page imports. If both `+page.rb` and `+page.haml` exist, an extensionless import like `import("./+page")` is ambiguous and Klenod asks for `import("./+page.haml")` or `import("./+page.rb")`. A `+route.rb` handler can live in the same directory as a page. For hybrid routes, browser-style `GET`, `POST`, and `HEAD` requests that prefer `text/html` render the page; API-style requests and `PUT`, `PATCH`, `DELETE`, and `OPTIONS` requests use `+route.rb`.
