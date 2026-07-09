# Troubleshooting

A symptom -> cause -> fix catalog for the most likely failure points in the
ai-infra-platform lab. Every entry uses placeholders only and references the
relevant mise task and deeper doc. See also [`developer-workflows.md`](developer-workflows.md),
[`ha-and-reliability.md`](ha-and-reliability.md), and
[`observability-taxonomy.md`](observability-taxonomy.md).

## Host prerequisites (init)

### `networks: [{lima: shared}]` fails to start the VM

- **Symptom.** `mise run lima:start` (or `limactl start`) errors on the `shared`
  network; the VM never gets a `lima0` IP on `192.168.105.0/24`.
- **Cause.** The Lima `shared` (socket_vmnet) network requires a root-owned
  `socket_vmnet` binary **and** a generated sudoers drop-in. Two things trip a fresh
  Mac: (1) Homebrew installs `socket_vmnet` under `/opt/homebrew`, but Lima only
  accepts a root-owned copy at `/opt/socket_vmnet/bin/socket_vmnet`; (2) Lima
  auto-generates `~/.lima/_config/networks.yaml` with `.paths.socketVMNet` pointing at
  the uid-owned Homebrew **Cellar** path, which it then rejects ("not owned by root") —
  so `lima:start` dies and `limactl sudoers` writes an **empty** `/etc/sudoers.d/lima`.
- **Fix.** Run `mise run init` — it prints the `sudo` commands to copy `socket_vmnet`
  into `/opt/socket_vmnet/bin` (root:wheel, 0755), and it sets `.paths.socketVMNet` in
  `networks.yaml` to that `/opt` path **before** the sudoers step. To do it manually:
  copy the binary (`sudo cp "$(brew --prefix socket_vmnet)/bin/socket_vmnet"
  /opt/socket_vmnet/bin/...` + `chown root:wheel` + `chmod 755`), set
  `yq -i '.paths.socketVMNet = "/opt/socket_vmnet/bin/socket_vmnet"'
  ~/.lima/_config/networks.yaml`, then `limactl sudoers | sudo tee
  /etc/sudoers.d/lima` and verify with `limactl sudoers --check`. The Homebrew
  socket_vmnet path is flagged "not secure" since v1.0.0 — only the root-owned
  `/opt/socket_vmnet` path is accepted.

### `mmdc` / `validate:mermaid` fails: "Could not find Chrome"

- **Symptom.** `mise run validate:mermaid` (or `mmdc`) errors with "Could not find
  Chrome" / a browser launch failure.
- **Cause.** mermaid-cli is pinned via the mise `npm:` backend, but `mise install`
  runs with `--ignore-scripts` and puppeteer is a peer dep, so **no headless
  Chrome is downloaded**.
- **Fix.** Run `mise run tools:mmdc-setup` once (it runs `npx puppeteer browsers
  install chrome` and verifies `mmdc`). `validate:mermaid` then renders against the
  committed `.config/mermaid/puppeteer-config.json` (`--no-sandbox`).

### A mise file-task does not run / "command not found"

- **Symptom.** `mise run <group>:<name>` reports the task as missing or refuses to
  execute the body.
- **Cause.** File-tasks live under `.config/mise/tasks/<group>/<name>` (extensionless,
  `:`-namespaced by directory) and **must be executable**; a non-`+x` file is not a
  runnable task.
- **Fix.** `chmod +x` the file-task. Each carries a `#!/usr/bin/env bash` shebang +
  `#MISE` header; `validate:shell` / `validate:shfmt` lint the tree by shebang. See
  [`developer-workflows.md`](developer-workflows.md).

## Cluster bring-up (kubeadm + Cilium + kube-vip)

### `kubeadm init` hangs on the API health check (super-admin.conf deadlock)

- **Symptom.** On `ai-inf-platform-0`, `kubeadm init` stalls waiting for the API server; the
  kube-vip static pod logs auth failures; the VIP never comes up.
- **Cause.** Since k8s 1.29, `kubeadm init` writes `admin.conf` (RBAC-bound) and
  `super-admin.conf` (RBAC-bypass) — but the `admin.conf` RBAC bindings do not
  exist yet during the first init, so a kube-vip static pod mounting `admin.conf`
  cannot authenticate → no VIP → the init API health check never passes
  (chicken-and-egg).
- **Fix.** The kube-vip static pod's `volumes[].hostPath.path` must be
  `/etc/kubernetes/super-admin.conf` **during** init (the container `mountPath`
  stays `/etc/kubernetes/admin.conf`). After init succeeds, sed-swap the host path
  back to `admin.conf`. The `lima:start` flow applies this automatically.

### Cilium agents `CrashLoopBackOff`: cannot reach the apiserver

- **Symptom.** Cilium pods never become Ready; agent logs show they cannot connect
  to the Kubernetes API.
- **Cause.** With `--skip-phases=addon/kube-proxy` there is no kube-proxy to program
  the `kubernetes` ClusterIP, so Cilium must be told the apiserver out-of-band — and
  `k8sServiceHost` is set to a single node IP (or `localhost`) instead of the VIP.
- **Fix.** Set `k8sServiceHost: 192.168.105.40` (the kube-vip VIP) and
  `k8sServicePort: 6443` in the Cilium values. It **must** be the VIP, not a node
  IP, or losing that node severs every agent from the API. See
  [`ha-and-reliability.md`](ha-and-reliability.md) §2.1.

### Nodes stuck `NotReady` until Cilium is installed

- **Symptom.** After `mise run lima:start`, `kubectl get nodes` shows nodes
  `NotReady`; pods stay `Pending` / `ContainerCreating`.
- **Cause.** kubeadm is bootstrapped **without a CNI** (Flannel is deliberately not
  applied — Cilium is installed out-of-band so the version/values are controlled),
  so there is **no pod networking until Cilium is installed**. This is expected.
- **Fix.** Run `mise run k8s:cilium` and wait for Cilium to report Ready; the nodes
  flip to `Ready` once the CNI is up. Only then run `mise run k8s:apply`.

### TLS error reaching `https://192.168.105.40:6443` (certificate is not valid for the VIP)

- **Symptom.** `kubectl` against the VIP fails with an x509 / "certificate is valid
  for ... not 192.168.105.40" error.
- **Cause.** The apiserver serving cert does not list the VIP in its SANs.
- **Fix.** `apiServer.certSANs` in the kubeadm `ClusterConfiguration` must include
  `192.168.105.40` (kubeadm auto-adds each node's `lima0` IP; `127.0.0.1` is also
  listed). Re-init / regenerate certs if the SAN was missing.

### Cilium / kube-vip bind the wrong NIC (eth0 instead of lima0)

- **Symptom.** Pod-to-pod routing or VIP ARP is broken; traffic uses the SLIRP NAT
  path; the VIP is unreachable from the Mac.
- **Cause.** Lima guests have two NICs — `eth0` (SLIRP NAT, user-mode) and `lima0`
  (the shared/socket_vmnet L2). Something bound `eth0`.
- **Fix.** Pin everything to `lima0`: kubelet `--node-ip` = the node's `lima0` IP,
  kube-vip `vip_interface: lima0`, Cilium `devices: lima0`, and the
  `CiliumL2AnnouncementPolicy` `interfaces: ['^lima0$']` (a device named there must
  also appear in the Cilium `devices` value).

### Service VIP not assigned / not reachable from the Mac

- **Symptom.** A `LoadBalancer` Service stays `<pending>` for its external IP, or
  the VIP is assigned but the Mac cannot reach it.
- **Cause.** One of: the wrong annotation key, the IP is outside the pool / collides
  with DHCP, `externalTrafficPolicy: Local`, or the wrong CRD apiVersion.
- **Fix.** Pin the IP with **`lbipam.cilium.io/ips`** (the correct key — not the
  old `io.cilium/lb-ipam-ips`), inside the `lima-shared-pool` block
  (`192.168.105.200-.250`, above the vmnet `dhcpEnd`). Use
  `externalTrafficPolicy: Cluster` (L2-announced `Local` can blackhole on pod-less
  nodes). Mind the 1.19 CRD split: `CiliumLoadBalancerIPPool` is `cilium.io/v2`
  (GA), `CiliumL2AnnouncementPolicy` is `cilium.io/v2alpha1` (Beta) — don't cross
  them. Confirm the host is on the same L2 (`192.168.105.x` on a Mac interface).

### Cilium cleanup must precede the kubeadm teardown

- **Symptom.** After a teardown, stale CNI interfaces / iptables rules remain and a
  fresh bring-up has broken networking.
- **Cause.** Tearing the cluster down before cleaning Cilium leaves orphaned
  interfaces and iptables/eBPF state.
- **Fix.** Always tear down via `mise run cluster:teardown`, which runs the
  **Cilium-interface + iptables cleanup BEFORE `kubeadm reset`** on each node, then
  deletes the VMs (`limactl stop` + `limactl delete`). Do not `kubeadm reset` first.

## Grafana "No data"

### Prometheus panels all show "No data"

- **Symptom.** Every Prometheus-backed panel is empty; queries 404.
- **Cause.** Prometheus runs with `--web.route-prefix=/prometheus`, so the query
  API lives under `/prometheus/api/v1/*`. The **datasource URL must include the
  `/prometheus` route-prefix** (`http://prometheus-server.lgtm.svc.cluster.local/prometheus`).
  Omitting it 404s every query. This is the single most common gotcha.
- **Fix.** Confirm the Prometheus datasource URL ends in `/prometheus`. The
  self-scrape `metrics_path` is likewise `/prometheus/metrics`.

### A sideloaded dashboard shows "No data" even though others work

- **Symptom.** A specific sideloaded dashboard is empty while gnetId dashboards work.
- **Cause.** Sideloaded dashboards **bake datasource UIDs**; stale
  `"uid":"Prometheus"` / `DS_*` placeholders do not resolve.
- **Fix.** jq-rewrite the stale UIDs to the real ones (Prometheus
  `PBFA97CFB590B2093`, Loki `P8E80F9AEF21F6940`, Tempo `P214B5B846CF3925F`) before
  sideloading.

### Some panels are blank until traffic flows

- **Symptom.** cilium-hubble L7 panels (or the k8s-views pods panel) show no data.
- **Cause.** Some panels only populate once the relevant traffic exists — Hubble L7
  panels need L7 traffic; the pods panel needs the kubelet `/metrics/resource`
  scrape.
- **Fix.** Generate the relevant traffic (run the demo / smoke flow) and confirm the
  scrape is configured; this is not a misconfiguration.

## OTLP ingest

### Telemetry not arriving / 404 on ingest

- **Symptom.** Spans/metrics/logs never reach the backends; the client logs OTLP
  errors.
- **Cause.** The OTLP HTTP endpoint is plain `:4318` with `/v1/{traces,metrics,logs}`
  paths. The old **`/otel` prefix is dropped** in v7 (it was an Ingress artifact);
  using `/otel/v1/*` 404s.
- **Fix.** Point clients at the OTel Collector service VIP
  `http://192.168.105.203:4318/v1/*` (or `http://127.0.0.1:34318/v1/*` via the
  `mise run port-forward:otel` fallback). Confirm there is no `/otel` prefix in any agent
  config.

### Large records silently dropped

- **Symptom.** Big captured bodies never appear in Loki/Tempo, smaller ones do.
- **Cause.** The default ~4 MiB OTLP caps drop large full-capture records.
- **Fix.** The platform sets a uniform **64 MiB** (`67108864`) ceiling across OTel
  Collector, Loki, and Tempo. If you touch one, change all and re-verify end-to-end
  (see [`observability-taxonomy.md`](observability-taxonomy.md)).

## Langfuse

### Lost API keys / undecryptable fields after a config change

- **Symptom.** Previously-working Langfuse API keys are rejected, or encrypted
  fields no longer decrypt.
- **Cause.** The Langfuse `SALT` and `ENCRYPTION_KEY` were rotated after first boot.
  **Rotating either permanently invalidates stored API keys and renders encrypted
  fields undecryptable.**
- **Fix.** **Never rotate `LANGFUSE_SALT` / `LANGFUSE_ENCRYPTION_KEY` after first
  boot** — generate once, seal, freeze. The secrets sync wrapper guards against
  overwriting them. There is no recovery once rotated; the prior encrypted state is
  lost. See [`secrets.md`](secrets.md).

### Bootstrap / first-boot delays

- **Symptom.** Langfuse web is not Ready for a while on first deploy.
- **Cause.** Migrations run on first boot; the startup probe is intentionally
  generous.
- **Fix.** Wait for the startup probe to pass; complete the headless bootstrap step
  before expecting the UI.

## LiteLLM passthrough / auth

### Subscription OAuth token dropped (passthrough fails)

- **Symptom.** Claude Code / Codex subscription passthrough fails auth at the
  provider even though the proxy accepts the request.
- **Cause.** A **custom proxy auth header name** was set. LiteLLM v1.90.0 hardcodes
  `x-litellm-api-key` in its OAuth auto-forward detector and refuses to forward the
  header it authenticated with — a custom name drops the client's `Authorization`
  (OAuth) token.
- **Fix.** Use the **default `x-litellm-api-key` header** for proxy auth (do NOT set
  `litellm_key_header_name`); the client's subscription OAuth then rides in
  `Authorization` and is forwarded unchanged. Confirm
  `forward_client_headers_to_llm_api: true`.

### Expecting `ANTHROPIC_API_KEY`

- **Symptom.** Setup looks for a provider API key that does not exist.
- **Cause.** v7 uses subscription/OAuth passthrough, not BYOK — there is **no
  `ANTHROPIC_API_KEY` anywhere**.
- **Fix.** Authenticate to LiteLLM with the per-client virtual key; the subscription
  credential is the client's own OAuth, forwarded by the proxy. See
  [`developer-workflows.md`](developer-workflows.md).

## Secrets (fnox / age)

### Decryption fails / no identity

- **Symptom.** `secrets:sync` cannot decrypt; fnox reports no age identity.
- **Cause.** No age identity is available to fnox.
- **Fix.** Supply the identity, in order of preference: a macOS Keychain identity in
  the gitignored `fnox.local.toml`; `FNOX_AGE_KEY_FILE` pointing at an age/SSH key (no
  password-protected SSH keys); or `FNOX_AGE_KEY` holding the secret-key string.
  Confirm the recipient public key is in `.agerecipients`, and that `fnox.local.toml`
  exists (run `mise run secrets:keygen` + `secrets:seal` if not). See
  [`secrets.md`](secrets.md).

### Decrypted material left behind

- **Symptom.** A `*.dec` file remains after a failed sync.
- **Cause.** A sync run was interrupted before its cleanup `trap` fired.
- **Fix.** The sync script removes the `.dec` via a `trap` on exit; if one remains,
  delete it (it is gitignored) and re-run `mise run secrets:sync`. Never commit
  decrypted material.

## Service-VIP and port-forward connectivity

### Cannot reach a UI on its service VIP

- **Symptom.** `curl http://192.168.105.20x:<port>` from the Mac refuses or times
  out.
- **Cause.** One of: the Mac is not on the `192.168.105.0/24` L2 (the `shared`
  network is not up); the Service has no Ready endpoints; or the L2 announcer is
  not announcing (e.g. wrong `interfaces` regex, or no control-plane node selected).
- **Fix.** Confirm a Mac interface holds a `192.168.105.x` address; confirm the
  target's pods are Ready (`mise run k8s:status`) and the Service shows an
  `EXTERNAL-IP` (`kubectl get svc -A | grep LoadBalancer`); confirm
  `kubectl -n kube-system get ciliuml2announcementpolicy` and `cilium status` are
  healthy. The `port-forward:*` tasks (`port-forward:litellm` / `port-forward:langfuse` / `port-forward:grafana` /
  `port-forward:otel`) are the **non-HA loopback fallback** if you cannot use the VIP.

### Cannot reach a UI on its loopback (port-forward) fallback

- **Symptom.** `127.0.0.1:<port>` refuses the connection.
- **Cause.** The port-forward task is not running, or the underlying Service has no
  Ready endpoints.
- **Fix.** Start the matching `port-forward:*` task and confirm the target's pods are Ready.
  Port-forward is the fallback only — it cannot follow a VIP failover, so prefer the
  service VIP for anything HA-sensitive (and for the `smoke:ha` checks).

### Grafana asks for a login

- **Symptom.** Grafana requires credentials; there is no anonymous view.
- **Cause.** Anonymous access is **disabled by design** (the source's no-login
  posture is replaced). Login is required.
- **Fix.** Use the admin credentials from the fnox-managed `GRAFANA_ADMIN_PASSWORD`;
  Grafana is reached at the service VIP `192.168.105.202:3000` (or `127.0.0.1:33001`
  via `port-forward:grafana`).

## Host services

### llama-server crash shows only an opaque error in Loki

- **Symptom.** A model backend crash logs only an `ExitError` with no detail.
- **Cause.** llama-swap does not proxy its child's stderr.
- **Fix.** Run llama-server through the stderr-tee wrapper (the deployed default) so
  the real error reaches Loki. See [`developer-workflows.md`](developer-workflows.md).

### Host thrashes when a dashboard loads

- **Symptom.** Loading certain metrics auto-loads a model and pins the host.
- **Cause.** Something scraped a per-model `/upstream/<model>/metrics` endpoint —
  every scrape there auto-LOADS the model.
- **Fix.** Scrape only the llama-swap aggregate `/metrics`; never the per-model
  endpoint.

### Default local model artifact is missing

- **Symptom.** `mise run models:check` fails, or `litellm:smoke` reaches the local
  route and the chat completion fails because the host backend cannot start.
- **Cause.** `AI_INFRA_DEFAULT_CHAT_MODEL` points at the default `mac-local/...`
  route, but the GGUF path from `AI_INFRA_DEFAULT_CHAT_MODEL_PATH` or the installed
  llama-swap launchd plist does not exist locally.
- **Fix.** Run `mise run models:fetch` — it downloads the default GGUF from its
  canonical Hugging Face repo against the pinned sha256 in
  `.config/mise/models.lock` and idempotently installs it at the configured path
  (checksum mismatch is fatal). Alternatively, place an already-obtained GGUF at
  the configured path, or update `AI_INFRA_DEFAULT_CHAT_MODEL_PATH` and keep the
  local launchd host-service environment in sync before reloading llama-swap.
  Then run `mise run models:check` before `mise run litellm:smoke`.

### macOS permission prompts for host-service paths

- **Symptom.** A host service prompts for access to protected directories.
- **Cause.** A service working path lives inside a macOS-protected (TCC-guarded)
  directory.
- **Fix.** Keep host-service paths out of protected directories; stage runnable
  host-service scripts (the llama-server wrapper, the macmon exporter) to the
  user-local bin directory.

## Related docs

- [`developer-workflows.md`](developer-workflows.md) — the mise task surface and bring-up.
- [`observability-taxonomy.md`](observability-taxonomy.md) — OTLP paths, route-prefix, datasource UIDs.
- [`ha-and-reliability.md`](ha-and-reliability.md) — failure-injection and recovery runbooks.
- [`secrets.md`](secrets.md) — fnox+age workflow and the never-rotate rule.
- [`kubernetes/README.md`](../kubernetes/README.md) — apply order and teardown.
