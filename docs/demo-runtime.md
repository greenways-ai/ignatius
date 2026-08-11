# Recursive runtime demo

Ignatius now has a recursive deterministic execution path suitable for a small,
recognisable Hara program rather than isolated operation fixtures.

The demo source is [`examples/agent_score.hal`](../examples/agent_score.hal). Its
canonical lowering performs all of the following in one operation graph:

1. creates a three-argument persistent function;
2. defines it in the account environment;
3. looks the function up and invokes it dynamically twice;
4. evaluates nested arithmetic expressions;
5. creates nested lexical bindings;
6. compares the two scores and evaluates one branch;
7. constructs a vector and canonically ordered map; and
8. returns a content-addressed result root with deterministic cost.

The expected semantic result is:

```clojure
{:winner "alice"
 :message "selected:alice"
 :scores [82 81]
 :spread 1}
```

## Execution changes

The recursive runtime keeps the original HCV0 operation vocabulary. An `invoke`
with a non-null `function-root` is a static primitive or persistent-function call.
An `invoke` with a null `function-root` treats its first child as a callable
expression and the remaining children as arguments. This permits ordinary Hara
forms such as `(score 9 7 8)` after `score` has been defined.

`let`, `def`, `cond`, `do`, function arguments, primitive arguments, and function
bodies now evaluate arbitrary supported child operations instead of narrow
constant/local subsets. Functions accept any fixed arity, capture the current
flattened lexical frame, and restore the caller frame after completion.

## Closed primitive surface

The demo runtime adds deterministic primitives for:

- integer addition, subtraction, multiplication and comparisons;
- canonical value equality and boolean negation;
- vector construction, count and indexed access;
- map construction, lookup and immutable association; and
- variadic string concatenation.

No primitive reads ambient time, randomness, network state, files, process state,
or mutable database rows outside the explicit execution context.

## Boundary

The source shown above is still compiled outside PostgreSQL. The frontend reads,
macroexpands and lowers it into HCV0 operation cells. Ignatius verifies and runs
the resulting graph. The database test constructs that exact graph directly so
that the execution semantics are covered before the general source compiler
bridge is added.