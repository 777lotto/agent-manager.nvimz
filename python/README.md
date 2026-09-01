# Agent Manager Claude worker

This package is the private, broker-owned Python boundary for the Claude Agent
SDK. It communicates through versioned JSON-RPC 2.0 frames on standard input
and standard output. Standard error is reserved for redacted diagnostics.

The worker is not a public service and never binds a listener. Run it through
the Rust broker or use the deterministic fake-adapter tests; live provider
probes are opt-in.
