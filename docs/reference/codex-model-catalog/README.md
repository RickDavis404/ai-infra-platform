# Codex model-catalog snapshots

Per-version archives of the model catalog that ships **compiled into** the `codex` binary.

Each file — `codex-<version>.json` — is the output of:

```sh
codex debug models --bundled | jq -S .
```

## Why `--bundled`

`--bundled` dumps the catalog baked into the binary — the copy codex falls back to when it
cannot reach the network. It takes **no network, no auth, and no gateway**, so the dump is
**deterministic and reproducible for a given codex version**: the same codex build always
emits the same catalog. `jq -S .` sorts object keys so successive versions diff cleanly
line-by-line.

## Why one file per version (append-only)

We keep **one snapshot per codex version, intentionally, as history**. Diffing
`codex-<old>.json` against `codex-<new>.json` shows exactly how the catalog changed across a
bump — models added or removed, reasoning-effort options, context/param changes — which is
otherwise invisible (the catalog lives inside the binary, not in any config we own).

Old per-version files are **never deleted**. A run only ever writes the file named for the
**current** codex version, so archiving a new version cannot disturb the earlier snapshots.

## Regenerating

Run the task after **every codex version bump**:

```sh
mise run codex:model-catalog-snapshot
```

It resolves the version from `codex --version`, writes `codex-<version>.json` here, and is
**idempotent** for the current version: re-running only overwrites that same-version file
(logging that it did so) and leaves every other snapshot untouched.
