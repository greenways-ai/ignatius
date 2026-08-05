# ignatius/noir

Portable Hara bindings for Noir compilation, proving, and verification. The
package depends on `ignatius/sha` for stable artefact identities.

Publication uses the typed `:node-hta` recipe. Hara's pinned web toolchain
bundles `@hara-lang/hta` and `@hara-lang/noir` into self-contained Node and
browser workers, so this component owns no handwritten JavaScript transport or
Noir runtime glue. Official builds resolve the committed recipe inputs during
preparation and run the build without network access.
