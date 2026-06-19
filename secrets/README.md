# `secrets/` — fnox + age secret store

This directory holds the age key material and the **placeholder** templates for the
ai-infra-platform lab. The guiding rule: **the repository is published**, so committed
files may contain public recipient keys and placeholder examples, but **never** a
decrypted secret value — and (belt-and-suspenders) not even ciphertext: real
age-encrypted values live only in the **gitignored** repo-root `fnox.local.toml`.

See `docs/secrets.md` for the full model and `§11` of the spec for the authoritative
specification.

## What lives here

| File | Committed? | Contents |
|---|---|---|
| `fnox.toml` (repo root) | ✅ committed | **marker-only template**: age provider config + `<fnox+age-managed>` placeholder for every sensitive key — no ciphertext |
| `fnox.local.toml` (repo root) | ❌ **gitignored** | your real age **ciphertext** store; fnox merges it over the template (local wins) |
| `.agerecipients` | ✅ committed | age/SSH **public** recipient keys (one per line) |
| `kustomization.yaml` | ✅ committed | SIMPLE-PREVIEW `secretGenerator` (renders 4 Secret shells from the `.dec` for structure preview; NOT the authoritative materializer — `mise run secrets:sync` is) |
| `shared.env.example` | ✅ committed | placeholder template of **every** sensitive key name |
| `litellm.env.example`, `langfuse.env.example`, `grafana.env.example`, `k3s.env.example` | ✅ committed | per-namespace placeholder views (derive from `shared.env`) |
| `README.md` | ✅ committed | this file |
| `shared.env`, `*.env` | ❌ **gitignored** | your real, plaintext values (generated/edited locally; never committed) |
| `shared.env.backup-*` | ❌ **gitignored** | timestamped teardown backups of generated plaintext values |
| `shared.env.dec`, `*.dec` | ❌ **gitignored** | runtime-decrypted env, produced by the sync task and deleted under a `trap` |
| `age/key.txt` | ❌ **gitignored** | your age **secret** key (the master decryptor) |

The `.gitignore` at the repo root enforces this (`*.dec`, `.env`, `.env.*` ignored;
`!*.env.example` negated to keep the templates tracked). **Never** commit a `*.dec`,
a real `*.env`, or `age/key.txt`.

## One-time setup (per operator/host)

1. **Generate an age key** (the secret key lives OUTSIDE git, in the gitignored
   `secrets/age/key.txt`):

   ```bash
   mise run secrets:keygen
   ```

   This runs `age-keygen`, writes the secret key to `secrets/age/key.txt` (gitignored,
   mode `600`), prints the **public** recipient line (`age1...`), creates the
   gitignored repo-root `fnox.local.toml` when missing, and syncs that public
   recipient into both `secrets/.agerecipients` and `fnox.local.toml`.

2. **Generate real values** into a gitignored working file and seal them:

   ```bash
   mise run secrets:generate  # fills missing fnox-managed keys with random values
   mise run secrets:seal      # encrypts fnox-managed values -> fnox.local.toml ciphertext
   ```

   `secrets:generate` preserves any existing non-placeholder value in
   `secrets/shared.env` and generates only missing/placeholder fnox-managed keys.
   `secrets:seal` refuses incomplete or placeholder values, encrypts to the recipients
   in the gitignored `fnox.local.toml`, and never prints a value. The committed
   `fnox.toml` template is never written to. Optional Docker Hub cache credentials
   remain in `secrets/shared.env` only and are not sealed.

## Seal / unseal / sync

| Task | File-task | What it does |
|---|---|---|
| `mise run secrets:keygen` | `.config/mise/tasks/secrets/keygen.sh` | `age-keygen` -> gitignored `secrets/age/key.txt`; prints and syncs the public recipient |
| `mise run secrets:generate` | `.config/mise/tasks/secrets/generate.sh` | generate/repair gitignored `secrets/shared.env` with strong random values; preserve existing non-placeholder values |
| `mise run secrets:seal` | `.config/mise/tasks/secrets/seal.sh` | encrypt `secrets/shared.env` -> gitignored `fnox.local.toml` ciphertext (no values printed) |
| `mise run secrets:unseal` | `.config/mise/tasks/secrets/unseal.sh` | decrypt `fnox.local.toml` -> gitignored `secrets/shared.env.dec` (key **names** only logged) |
| `mise run secrets:sync` | `.config/mise/tasks/secrets/sync.sh` | **authoritative materializer**: decrypt -> `.dec` -> create EACH namespaced Secret with the exact consumer key names (remapping fnox keys), incl. CNPG `*-app` basic-auth + SeaweedFS config JSON + cross-ns S3 mirrors -> `kubectl apply --server-side`; `.dec` removed under `trap` |

All secrets file-tasks source `.config/mise/lib/common.sh` and **never echo a secret value** —
they log key **names** and counts only.

## Cross-namespace mirroring

A single `shared.env.dec` is the source for every namespaced Secret. The same
decrypted value (e.g. `VALKEY_PASSWORD`, `LANGFUSE_PG_PASSWORD`) is written into
multiple namespaces' Secrets from one file, so **rotating a value = re-seal once in
fnox + re-run `secrets:sync`**; every namespace picks up the new value. There is no
hand-copied "KEEP IN SYNC" duplication.

## Docker Hub pull-through cache auth (out-of-band; NOT sealed into fnox)

`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are an **optional, special case**: they
authenticate the long-lived `ai-registry` Docker Hub **pull-through cache** VM (see
`lima/templates/registry.yaml` and `mise run cache:up`) to Docker Hub for higher pull
limits (authenticated personal = 200 pulls / 6 h vs anonymous 100), which is what lets
repeated cold cluster standups dodge the `docker.io` HTTP 429 rate limit.

Unlike every other key here, they are **read directly from the gitignored
`secrets/shared.env` at runtime** by `cache:up` and written into the **gitignored**
`.local/registry/config.yml` (the registry proxy config inside the VM's host mount).
They are **deliberately NOT** sealed into the fnox store and **NOT** materialized as a
Kubernetes Secret — so adding them does not require re-running `secrets:seal` or
rebuilding the sealed store.

- **Optional.** If they are absent (or left as `CHANGEME-…` placeholders), the cache
  runs **anonymously** with a logged warning — it still works, just with the lower
  anonymous pull limit.
- **Use an access token, not your password.** Create one in Docker Hub → Account
  Settings → Personal access tokens.
- **Never leaked.** The token only ever exists in the gitignored `secrets/shared.env`
  (input) and the gitignored `.local/registry/config.yml` (output). `cache:up` /
  `cache:status` log its **presence** only, never its value, and never `cat`/`echo` it.

To enable: set both in `secrets/shared.env`, then `mise run cache:up`.

## Write-once values — NEVER rotate

`LANGFUSE_SALT` and `LANGFUSE_ENCRYPTION_KEY` are **write-once**. Langfuse hashes API
keys with `SALT` and encrypts integration credentials with `ENCRYPTION_KEY`. Rotating
either after the first successful boot **permanently invalidates** previously stored
API keys and renders encrypted fields undecryptable. Generate them **once**, seal
them, and never change them for the life of the deployment. The sync wrapper guards
against overwriting them after first boot (§11.6).

## Hard rules

- **Never commit decrypted material** — no `*.dec`, no real `*.env`, no `age/key.txt`,
  no rendered Secret YAML.
- **Never print a secret value** — scripts and logs show key names and counts only.
- **Public keys only in git** — `.agerecipients` and the committed `fnox.toml`
  template carry recipients (public) and `<fnox+age-managed>` markers only; even the
  ciphertext stays out of git (gitignored `fnox.local.toml`), and the secret key
  never leaves `secrets/age/`.
- **Idempotent apply** — `secrets:sync` uses `kubectl kustomize | kubectl apply -f -`
  so re-runs update rather than fail.
