# Security policy

## Supported versions

Security fixes are applied to the current `bluff` branch and latest signed
release. Supported provider and runtime versions are listed in the release
compatibility manifest.

## Reporting a vulnerability

Use the repository Security tab to report credential exposure, unsafe approval
handling, socket or archive path traversal, arbitrary command execution, or
release provenance failures privately. Do not open a public issue containing
prompts, tool payloads, provider responses, credentials, or private paths.

Agent Manager never receives provider credentials directly. Provider child
commands are argv arrays, approval and question callbacks fail closed, the
durable listener is an owner-only Unix socket, and release assets are accepted
only after checksum, payload, compatibility, and clean-source verification.
