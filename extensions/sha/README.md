# ignatius/sha

Portable Hara SHA-256 API backed by an HTA v1 WebAssembly provider.

```clojure
(ns app (:require [ignatius.extension.sha :as sha]))
(deref (sha/digest (bytes 97 98 99)))
```

The provider depends on the pinned public `hara-wasm` embedding crate rather
than including Hara runtime source modules directly. Run `make setup` from the
repository root before building or testing it.

Build with the typed `:rust-wasm` recipe, then install with
`hara package install`.
