# klenod

`klenod` is the compatibility/meta gem for Klenod.

It depends on the build and Rack packages and exposes the broad development surface through:

```ruby
require "klenod"
```

Install this gem when you want the full Klenod toolkit in development. Production bundle loaders can depend directly on `klenod-runtime` instead.

The `klenod` executable wrapper also lives here and delegates to the build CLI implementation.
