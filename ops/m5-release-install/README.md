# M5 release artifact installation

This phase installs the attested Agent Manager v0.1.0 release without running
Cargo, uv, pip, or any dependency resolver on the destination machine. The
release archive contains the native Linux x86_64 broker, the exact relocatable
Python 3.13 interpreter, and the hash-locked worker packages. Installation
extracts one immutable release tree, then switches the stable M4 paths with
atomic symlinks.

For a normal Lazy-managed installation, run:

```sh
./ops/m5-release-install/install-current.sh
```

The portable wrapper requires Linux x86_64, Python 3.11 or newer, Git,
Coreutils/Findutils, and `flock` from util-linux; `curl` is needed only when
verified assets are not already cached, and `gh` is needed only when
attestation is explicitly required.

`nvim-config` invokes that command as Agent Manager's Lazy build hook, so it
runs after the plugin is first installed or its reviewed lock pin changes—not
at every Neovim startup and not during `:DevPlugins`. It derives canonical
paths from the current user's XDG directories, records them in a mode-0600
versioned `install.env`, serializes concurrent installs, reuses verified cached
assets, and performs a network-free no-op when the matching runtime is already
healthy. Set `AGENT_MANAGER_REQUIRE_ATTESTATION=1` to require `gh attestation
verify` in addition to the mandatory outer and inner checksums.

The checked-in `m5.env` remains the reviewed production-container parameter
boundary for an operator-driven install. Place the two v0.1.0 release assets at
its `RELEASE_ARCHIVE` and `RELEASE_CHECKSUMS` paths. Before moving assets into
the container, the operator can verify the keyless GitHub build attestation:

```sh
gh attestation verify \
  agent-manager-v0.1.0-x86_64-unknown-linux-gnu.tar.gz \
  --repo 777lotto/agent-manager.nvimz
```

Run every phase as the service user; none uses sudo:

1. `00-preflight.sh`
2. `10-install-release.sh`
3. `20-activate-release.sh`
4. `90-verify.sh`

The preflight verifies the release checksum, safe archive shape, internal
payload checksums, clean source marker, target, tagged source revision when
known, and bundled Python runtime. It also refuses to change stable paths while
`agent-manager-broker.service` is active. The verifier performs a real broker
`contract-info` call and a private Claude worker initialization handshake, then
writes credential-free evidence under the versioned
`~/.local/state/agent-manager/release-install/` directory.

After this phase passes, a container that needs agents to survive Neovim exits
can install and enable the durable user service using
`ops/m4-durable-service/` in its documented order. The portable default stays
embedded, and upgrades never restart an active durable broker implicitly.

The portable install reports its exact paired rollback command on success:

```sh
./ops/m5-release-install/undo-current.sh
```

An operator-driven rollback runs the underlying phases in reverse order while
the service is inactive:

1. `undo-20.sh`
2. `undo-10.sh`

Undo restores prior managed symlink targets and removes only versioned trees
that this phase proved it created. Unknown files, non-symlink stable paths,
changed links, active services, and pre-existing versioned releases are
preserved and reported instead of overwritten or deleted. Downloaded,
checksummed release assets and status evidence remain as an audit cache.
