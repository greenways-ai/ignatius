---
title: Storage
description: Canonical values, immutable blocks, scoped refs, and rebuildable projections.
---
# Storage

Provider-neutral immutable storage holds exact blocks and values. Small scoped compare-and-set refs identify selected heads. Large Git or object-store payloads remain outside ordinary canonical values and enter records through exact references.

Projection tables are operational indexes. They may be rebuilt from canonical chain state and must never become a second authority.
