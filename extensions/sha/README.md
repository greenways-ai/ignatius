# gw/ledger.sha

Portable Hara SHA-256 API backed by an HTA v1 WebAssembly provider.

```clojure
(ns app (:require [gw.ledger.sha :as sha]))
(deref (sha/digest (bytes 97 98 99)))
```

Build with the typed `:rust-wasm` recipe, then install with `hara package install`.
