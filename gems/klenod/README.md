# klenod

`klenod` provides the full development toolkit for
[Klenod](https://github.com/aalin/klenod).

It depends on [klenod-build](https://github.com/aalin/klenod/tree/main/gems/klenod-build),
[klenod-runtime](https://github.com/aalin/klenod/tree/main/gems/klenod-runtime),
and [klenod-rack](https://github.com/aalin/klenod/tree/main/gems/klenod-rack).

Use this gem when you want the complete Klenod API and development tooling:

```ruby
require "klenod"
```

Production applications that only load generated bundles can depend directly
on `klenod-runtime` instead.

The `klenod` executable wrapper also lives here and delegates to the build CLI implementation.
