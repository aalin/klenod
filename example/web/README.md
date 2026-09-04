# Klenod Web Example

This example is a small web application built with Klenod.

## Getting started

From the repository root, install the dependencies and compile the native
JavaScript and CSS plugin extensions once:

```sh
bundle install
bundle exec rake -C gems/klenod-plugin-javascript compile
bundle exec rake -C gems/klenod-plugin-css compile
cd example/web
bundle install
```

The remaining commands are run from `example/web/`.

Start the development server:

```sh
bin/dev
```

Then open `https://localhost:9292`. The server uses the `localhost` gem for its
local TLS certificate and supports HTTP/2 when the client does.

To try the production flow, build the app before starting the runtime server:

```sh
bin/build
bin/server
```

`bin/server` defaults `RACK_ENV` to `production`. In production, the main
navigation omits the exploratory `/demo` link; the demo routes remain available.

Page routes also provide a content-negotiated Markdown representation:

```sh
curl --insecure -H 'Accept: text/markdown' https://localhost:9292/docs/getting-started
```

Markdown responses contain the page content without route layouts or browser
assets and include `Vary: Accept` for caches.

## Commands

- `bin/dev` starts the development server.
- `bin/build` builds a production bundle and writes its assets.
- `bin/server` loads and serves the production bundle.
- `bin/routes` prints the discovered routes.
- `bin/test` delegates to `klenod test`, which runs colocated application tests and watches their dependency graph.
- `bin/coverage` runs the complete colocated test suite once and reports application coverage.

Use `bin/test --run` or `bundle exec klenod test --run` for one test run. The command also runs once automatically when `CI` is set. Tests live beside source modules as `*.test.rb`; when watching, changing a test or any eager or lazy dependency reruns only the related tests.

The command uses `klenod-test` for dependency-aware watching and fresh worker processes. `klenod.test.rb` connects it to the example's Minitest adapter. The component helpers and reporter remain under `lib/testing`.

The example selects the partial report in `klenod.test.rb`, so `bin/coverage` shows uncovered original Ruby and Haml lines. Applications using the general `klenod coverage` command can override their configured `report` and `minimum` values with command-line options.

The example framework's `render` test helper serializes a component to HTML and parses it with Nokolexbor. The returned fragment supports strict role, text, and CSS queries, scoped queries with `within`, and direct Nokolexbor attribute access:

```ruby
screen = render(Button, "Save", type: "submit")
button = screen.get_by_role(:button, name: "Save")

assert_equal("submit", button["type"])
```

Role queries implement a deliberately small model of static HTML accessibility semantics. They are not a browser accessibility tree and do not simulate clicks, focus, JavaScript, layout, or computed styles.

By default, development assets stay in memory. They can also be mirrored to
disk; the initial manifest and subsequent successful asset updates are written
to the selected directory:

```sh
ASSETS_DIR=tmp/public bin/dev
```

## How the build works

The build configuration is in `lib/web_config.rb`. The build starts at
`src/entrypoint.rb`. Klenod reads the imports and collects the modules into a
graph. Plugins transform the source files and create assets. Collection does
not evaluate the application modules.

`bin/build` writes the assets and serializes the graph. `bin/server` loads the
bundle with `klenod-runtime`. The runtime evaluates each module when the
application uses that module.

In development, Klenod keeps the graph active. After a source change, Klenod
updates the changed module and its dependents. The production server uses
`source_root:` to set the correct paths for `__FILE__`, source maps, and
backtraces.

## Source layout and routing

`src/` contains the web application. `src/entrypoint.rb` connects the generated
router and `src/root.haml` document shell to the server. The root component owns
the `html`, `head`, and `body` elements and renders the ordered route stylesheet
and module-script references passed by the router app. Its `root.css` and
`root.intl.*.toml` companions provide document-wide styles and metadata.
`src/routes/` contains the routes, `src/components/` contains reusable
components, and `lib/` contains the small example web framework.

Klenod builds the route tree from `src/routes/`. A `+page.haml` or `+page.rb`
file defines a page. A `+layout` file wraps pages in its directory and child
directories inside the root document body. `+error` and `+not-found` files
handle errors and missing pages.
Klenod collects companion CSS and translation files with each Haml file.

Directory names define dynamic, catch-all, grouped, parallel, and intercepted
segments. A `+route.rb` file defines HTTP handlers. A directory can contain a
page and a handler. This is a hybrid route. For a hybrid route, `GET`, `POST`,
and `HEAD` render the page when the request prefers HTML. Other requests use the
handler.

## Inspecting and profiling builds

Export a built bundle graph as Graphviz DOT and render it as SVG:

```sh
bundle exec klenod graph dist/klenod.bundle > graph.dot
dot -Tsvg graph.dot > graph.svg
```

Profile a build with Vernier:

```sh
bundle exec vernier run -- bin/build
```

Vernier writes a profile in the current directory. View a terminal summary with
`bundle exec vernier view -- <profile>`, or open it in a compatible profile
viewer.

## Containers

Build and run the production container from `example/web`:

```sh
podman build -t klenod-example-web .
podman run --rm -p 9292:9292 klenod-example-web
```

Then open `http://localhost:9292`. The container serves plaintext HTTP/2 or
HTTP/1.x so a deployment proxy can terminate TLS. The included `fly.toml`
configures Fly Proxy to use HTTP/2 cleartext (h2c) between the proxy and the
container.

The default container build installs the published Klenod gems from RubyGems.
Before deploying, set `KLENOD_VERSION` in `Dockerfile` to a version that has
been published. You can also override it for one build:

```sh
podman build --build-arg KLENOD_VERSION=0.0.2 -t klenod-example-web .
```

To build the same image from the gems in this repository while developing
Klenod, use `Dockerfile.dev` instead:

```sh
podman build -f Dockerfile.dev -t klenod-example-web ../..
```

Both multi-stage images use the complete build stack to create `dist/`. Their
final runtime image contains the built application and its runtime gems, but
not `klenod-build` or the compatibility `klenod` gem.
