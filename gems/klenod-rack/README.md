# klenod-rack

`klenod-rack` provides Rack-compatible serving helpers for Klenod runtime assets.

It is intentionally small and framework-agnostic. The main entrypoint is `Klenod::Rack::AssetApp`, which serves content-hashed assets from a build context or loaded runtime bundle and can delegate non-asset requests to another Rack app.

```ruby
require "klenod/rack"

assets = Klenod::Rack::AssetApp.new(bundle, assets_dir: "public")
```
