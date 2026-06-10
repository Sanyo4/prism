# prism-indexer

Linux x86_64-only Python CLI that scans a music folder and writes
`.sonic.json` sidecars beside each audio file.

```sh
# install (Phase A — scaffold only, no Essentia / TF):
python3.12 -m venv .venv && . .venv/bin/activate
pip install -e ".[test]"

# install with Essentia + TF for real analysis (Phase B):
pip install -e ".[analysis,test]"

# run:
prism-indexer scan ~/Music
```

Models land in `~/.cache/prism/models/` on first run. The indexer
never touches the network beyond that fetch.
