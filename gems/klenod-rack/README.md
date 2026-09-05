# klenod-rack

`klenod-rack` provides Rack-compatible serving helpers for
[Klenod](https://github.com/aalin/klenod) runtime assets.

It is intentionally small and framework-agnostic. `Klenod::Rack::AssetApp`:

- serves content-hashed assets from a build context or loaded runtime bundle
- serves precompressed Brotli assets when available
- can delegate non-asset requests to another Rack application

Use this gem when exposing Klenod assets from a Rack-compatible server:

```ruby
require "klenod/rack"

assets = Klenod::Rack::AssetApp.new(bundle, assets_dir: "public", base: bundle.base)
```

Assets are written directly under `assets_dir` using their root-relative output paths.
`AssetApp` maps an origin-relative build base such as `/assets/` or `/.assets/` to
those files. For an external base such as a CDN URL, use `path_prefix:` to choose
the local path it should serve.
