# Ignatius development environment

The Ubuntu 24.04 devcontainer and Codex cloud share one idempotent bootstrap.
Codex runs the script in its universal image rather than building this
Dockerfile, and may invoke it again for cached-environment maintenance.

## Setup and maintenance

```sh
bash .devcontainer/post-create.sh
```

Use these Codex environment values:

- **Setup script:** `bash .devcontainer/post-create.sh`
- **Maintenance script:** `bash .devcontainer/post-create.sh`
- **Agent internet access:** not required for the boundary, migration, release, HAL, generator, SHA-extension, and site checks after setup
- **Docker integration:** run from the devcontainer or Codespaces only when `docker info` succeeds

The script preflights existing dependency checkouts before invoking
`scripts/setup-dependencies`. Dirty or mismatched Hara/Foundation work fails
before that reset-capable helper can run. It then builds and installs Hara,
prefetches Lein and SHA-extension graphs, and installs site packages.

## Representative offline checks

```sh
bash scripts/check-architecture-boundaries
bash scripts/check-ledger-hal-parity
cargo +1.88.0 test --locked --manifest-path extensions/sha/rust/Cargo.toml
npm run build --prefix site
```

Run the repository's HAL checks/tests and Lein generators with their documented
commands, then require a zero `git status --short` diff. Docker-dependent checks
are unavailable in Codex cloud when no daemon is attached. Setup does not create
a PostgreSQL database, start services, or generate credentials/private state.
Ports `4321` and `5432` are forwarded for explicit development commands.
