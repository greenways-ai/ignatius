# PostgreSQL workspace commit projection

The PostgreSQL workspace module projects verified canonical
`:workspace/commit-candidate` values into queryable rows without changing their
HCV0 identity.

## Authority

The canonical HCV0 map and its ordered parent vector are authoritative.
`WorkspaceCommit` and `WorkspaceCommitParent` are rebuildable indexes. A row is
valid only when every projected field and parent position matches the immutable
value graph under the supplied commit root.

## Admission order

Parents are projected before children. This gives the verified projection an
acyclic edge direction and permits deterministic ancestry and merge-base
validation without making the global Ignatius ledger branchable.

The accepted shapes are:

```text
genesis  zero parents, no merge fields
edit     one parent, no merge fields
merge    two or more parents, explicit merge base and merge-policy root
```

Every parent must already exist, belong to the same workspace, and appear only
once. A merge base must be an ancestor of every merge parent.

## Traversal

Ancestry uses one deterministic pending-root traversal rather than mutually
recursive SQL functions. Shared ancestors are visited once. This mirrors the
portable workspace DAG and the existing snapshot reachability pattern.

## Mutable selection

This projection does not select a branch head. Selection remains the
responsibility of the independent `ScopedRef` exact-root compare-and-set adapter.
The next admission slice will verify a signed workspace-ref intent, validate the
candidate commit, apply explicit authority policy, advance the scoped ref, and
bind the result to the linear transaction and receipt chain.
