# Agent Manager Claude worker

This package is the private, broker-owned Python boundary for the Claude Agent
SDK. It communicates through versioned JSON-RPC 2.0 frames on standard input
and standard output. Standard error is reserved for redacted diagnostics.

The worker is not a public service and never binds a listener. Run it through
the Rust broker or use the deterministic fake-adapter tests; live provider
probes are opt-in.

The locked environment is the reproducible tested baseline, not a public
protocol pin. During initialization the worker advertises the
`claude-agent-sdk-v1` compatibility profile plus the actual SDK and bundled
Claude Code versions. A broker accepts the profile/capability report and stores
those actual versions with the agent; it does not require one hard-coded patch
version.
