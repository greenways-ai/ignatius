---
title: Authority boundary
description: Separate canonical coordination from application policy and host mechanics.
---
# Authority boundary

Ignatius owns signed transaction admission, deterministic execution, linear commitment, and exact receipts. Git owns file history and merging. Tahto owns semantic storage and synchronization. Object stores own large payload bytes. Applications own their workflows and interfaces.

A host adapter may verify provider input and prepare a payload, but it cannot grant Ignatius authority. The actual account signs the exact canonical transaction submitted to the chain.
