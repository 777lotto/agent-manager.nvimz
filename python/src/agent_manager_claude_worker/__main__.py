"""Module entry point that preserves stdout for protocol frames."""

from __future__ import annotations

import asyncio
import logging

from .worker import run_stdio


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s agent-manager-claude-worker %(message)s",
    )
    asyncio.run(run_stdio())


if __name__ == "__main__":
    main()
