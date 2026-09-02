# Contributing

Issues and pull requests should describe the protocol, runtime, editor, release,
or integration problem before the proposed implementation.

## Branch model

- `bet` is the production/default branch.
- `bluff` is the persistent integration branch.
- Short-lived branches start from and return to `bluff`.
- A `bluff` to `bet` pull request promotes a verified milestone.

Do not target `bet` directly for ordinary changes. Commits and annotated
Semantic Versioning release tags should retain the repository's configured
signing behavior.

## Local checks

Install the versions pinned in `mise.toml`, install Codex 0.152.0, make the
three UX checkouts available at the revisions in `tests/ux-pins.env`, and run:

```sh
mise run verify
```

The gate is deterministic and provider-offline. Do not add a live turn,
credential requirement, or provider quota usage to ordinary CI. Live provider
probes remain explicit diagnostics only.

Protocol changes require implementation, versioned schema, fixtures, malformed
input coverage, cancellation behavior, and both Rust/Python acceptance where
the private worker contract is involved. Release changes must preserve
reproducibility, checksum coverage, safe extraction, paired installer undo, and
the invariant that Neovim startup never installs dependencies.

Never log or place in fixtures any prompt, tool payload, response, credential,
provider authentication material, or private user path.
