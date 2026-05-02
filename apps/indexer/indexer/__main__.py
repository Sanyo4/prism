"""Make ``python -m indexer`` work the same as the ``prism-indexer``
console script. Useful in CI / dev environments where the script
shim isn't on PATH (e.g. running directly from a checkout without
``pip install -e .``).
"""

from indexer.cli import main

if __name__ == "__main__":
    main()
