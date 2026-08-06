# Language protocols and macros

Ignatius distinguishes Hara language forms from the immutable operation graph that a
transaction signs.

## `defprotocol`

A frontend lowers a validated form such as:

```clojure
(defprotocol IMeow
  (meow [self]))
```

into an invocation of the closed `protocol/define` intrinsic. Its two arguments are
the canonical protocol-name symbol root and a canonical method-name to arity map.
The original syntax root remains the transaction `form-root`; the lowered invocation
is the transaction `op-root`.

Successful execution commits:

- an immutable protocol descriptor;
- an immutable dispatcher descriptor for every method;
- the protocol name binding in the account environment; and
- each method name binding in the same account environment.

The whole definition is one deterministic account-state transition. Existing
unrelated bindings are not overwritten. Replaying the exact same definition is
idempotent.

## `extend-type`

`extend-type` lowers to `protocol/extend` with the protocol-name root, canonical type
root, and a complete method-name to function-root map. Ignatius verifies that every
required method exists and that each persistent function has the declared arity.
The resulting implementation record is immutable; the active implementation is
selected by a deterministic account binding derived from the protocol and type roots.

Values may use a canonical explicit type wrapper. Ordinary HCV1 values dispatch
against a stable built-in type descriptor derived from their HCV1 type tag.

## Method invocation

A protocol call lowers to the variadic `protocol/invoke` intrinsic. The first two
arguments are the protocol and method roots, followed by the ordinary receiver and
method arguments. The protocol-aware executor:

1. evaluates arguments from left to right;
2. derives the receiver type root;
3. resolves the implementation against the transaction's immutable state root;
4. verifies method and function arity;
5. installs the arguments as the function's local frame; and
6. executes the committed function body.

The PostgreSQL adapter is not parsing source text. Parsing, macro expansion and
lowering happen in the pinned Hara frontend; Ignatius independently verifies and
executes the resulting canonical operation graph.

## `defmacro`

The full Hara kernel supports `defmacro`. Ignatius deliberately treats macros as a
compiler-phase facility rather than a ledger runtime operation.

A signed macro-bearing transaction should retain:

- the original `form-root`;
- the macro function or publishing module root;
- the pinned compiler root; and
- the expanded operation root that is actually executed.

This prevents database execution from depending on ambient compiler state while
still making macro provenance auditable and reproducible. A future compiler receipt
can commit the expansion trace, but PostgreSQL should never evaluate arbitrary macro
code during transaction admission.
