#!/usr/bin/env python3
"""Python conformance entrypoint (SPEC/20-b1-canon-1.md §5).

    stdin  : a JSON document
    stdout : 64 lowercase hex digits + newline
    stderr : a B1_ERR_* token when the document is rejected
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from b1_quality.canon import B1Error, digest_text  # noqa: E402


def main() -> int:
    text = sys.stdin.read()
    try:
        sys.stdout.write(digest_text(text) + "\n")
        return 0
    except B1Error as err:
        sys.stderr.write(err.token + "\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
