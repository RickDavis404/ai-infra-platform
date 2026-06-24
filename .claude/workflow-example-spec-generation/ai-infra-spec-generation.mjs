export const meta = {
  name: 'ai-infra-spec-generation',
  description:
    'Generate a definitive ai-infra-platform project spec from an instructions file via granular research + spec-writer subagents, integration, and independent validation.',
  whenToUse:
    'Run once per model/effort instruction variant in planning/ to produce a single definitive spec markdown file. Spec-only: never implements or migrates repo files.',
  phases: [
    { title: 'Research', detail: 'granular source-review + doc-verification subagents write reports' },
    { title: 'Synthesize', detail: 'reconcile findings into one decision model (handoff.md)' },
    { title: 'Draft', detail: 'spec-writer subagents draft major spec areas' },
    { title: 'Integrate', detail: 'assemble drafts into one spec (orchestrator-owned)' },
    { title: 'Validate', detail: 'independent consistency + publication-safety review' },
  ],
};

/*
 * ─────────────────────────────────────────────────────────────────────────────
 * FAITHFULNESS NOTE — read before running.
 *
 * This script encodes the pipeline that was actually executed by hand for the
 * opus-4-8-1m/v6 spec. In that run:
 *   - Phases Research / Draft / Validate were run as parallel `Agent` calls.
 *   - Synthesize and Integrate were done by the MAIN agent (me), not a subagent:
 *     synthesis = reconciling ~27 reports into research/handoff.md; integration =
 *     a deterministic shell assembly (awk heading-normalizer that renumbers
 *     headings by dotted depth + strips draft titles/HTML-comments/"Integration
 *     Notes"; perl literal-match caption cleanup; a ToC generator that derives
 *     GitHub anchors from the actual headings so links always resolve; Python
 *     consistency/scrub/fence/ASCII checks).
 *
 * Workflow scripts have NO filesystem/Node access, so the shell integration
 * cannot live in this script. Two honest options are encoded below:
 *   (A) DEFAULT: stop after Draft and hand control back to the orchestrator,
 *       who performs synthesis + integration with shell tools and keeps final
 *       responsibility (this mirrors the real run and the instructions' rule
 *       that the main agent must not delegate final integration).
 *   (B) OPTIONAL: an `integrate` agent that does the shell assembly itself.
 *       Enable by passing args.delegateIntegration = true. Use with care — the
 *       orchestrator must still review and own the result.
 *
 * The instruction file's planning-dir boundary is enforced in every prompt:
 * subagents may read/write ONLY the target spec file + research/ + spec/ (and,
 * for the implementation pass, implementation/). They must not read other
 * planning files.
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * ARGS (pass as a JSON object to Workflow `args`; defaults match opus-4-8-1m/v6):
 *   {
 *     planningDir:  "planning/claude/example-model",
 *     specOut:      "planning/claude/example-model/ai-infra-platform-spec.md",
 *     k8sSrc:       "planning/inputs/kubernetes",
 *     dotfilesSrc:  "planning/inputs/dotfiles",
 *     delegateIntegration: false
 *   }
 */

const A = (typeof args === 'object' && args) ? args : {};
const PLAN = A.planningDir ||
  'planning/claude/example-model';
const SPEC = A.specOut ||
  `${PLAN}/ai-infra-platform-spec.md`;
const K8S = A.k8sSrc || 'planning/inputs/kubernetes';
const DOT = A.dotfilesSrc || 'planning/inputs/dotfiles';
const DELEGATE_INTEGRATION = !!A.delegateIntegration;

const RESEARCH = `${PLAN}/research`;
const SPECDIR = `${PLAN}/spec`;

// Boundary clause stamped into every subagent prompt.
const BOUNDARY = `
HARD RULES:
1. Do NOT read any files under the repo's \`planning/\` directory EXCEPT this
   variant's own \`research/\` and \`spec/\` subtrees (${RESEARCH}, ${SPECDIR}).
   Never read other instruction or spec files.
2. Write your detailed report/draft ONLY to the single path given to you.
3. Source review is read-only and informs the spec only — do NOT create,
   migrate, or scaffold any repo files.
4. Never copy real secrets, tokens, API keys, private hostnames, personal
   emails, or private org/project names into your output. Note them generically
   (masked) and flag them as scrub items.
5. Return a CONCISE chat summary (sources, facts/constraints, recommendations,
   risks/scrub concerns, the report path) — not large copied file contents.
6. If a Mermaid diagram is in scope, use the project's \`design-doc-mermaid\`
   skill to pick the type, generate with high-contrast styling, and validate;
   record which guide you used.`;

// ── Phase 1: Research (barrier — synthesis needs all of it) ─────────────────
// Granular split: one subagent per subsystem / tool. ~27 total.
phase('Research');

const k8sSource = [
  ['k8s-cluster', 'cluster / bootstrap / cilium / common / namespaces / ingress / operators (ignore out-of-scope dirs: milvus, pgvector, attu, headlamp, eval-stack, gvisor, deepeval, inference-matrix)'],
  ['k8s-litellm', 'litellm/ + model routing, virtual keys, header forwarding, model catalog, hardcoded model paths'],
  ['k8s-langfuse', 'langfuse/ + langfuse-data/ (Postgres/ClickHouse/Valkey/SeaweedFS externalization, Bitnami subcharts, bootstrap)'],
  ['k8s-lgtm', 'lgtm/ + observability.md + otel notes (Grafana/Loki/Tempo/Prometheus/OTel, datasources, anonymous-admin, redaction, identity taxonomy)'],
  ['k8s-secrets-agents', 'secret generation, fnox/age/sops/1Password usage, .codex/.claude project config, .mcp, .gitignore'],
  ['k8s-host-services', 'CODEX-TELEMETRY-DATAFLOW + mac-side serving (llama-swap/llama-server/mlx_lm.server/macmon/host OTel), VM->host bridge, POC lessons'],
  ['k8s-scrub', 'publication-safety sweep: private hosts, tokens, emails, legacy org/codenames, real home paths, alternate VM runtimes, excluded subsystems (mask everything)'],
];
const dotSource = [
  ['dotfiles-mise', 'mise.toml + 10-mise.zsh: task naming/grouping/validation style, conf.d activation WITHOUT global mutation (style only; no chezmoi/home assumptions)'],
  ['dotfiles-shell', 'scripts/ + LIMA-NOTES + COMMENT-REVIEW: bash conventions, Lima/k3s/user-v2 findings, comment hygiene; what NOT to copy'],
  ['dotfiles-brew', 'Brewfile/brew bundle + pre-commit + shellcheckrc/editorconfig patterns reusable for required tool set; gaps (gitleaks, fnox, mlx-lm, otelcol)'],
  ['dotfiles-scrub', 'unrelated dotfiles to exclude (iTerm/Rectangle/archive/chezmoi/editor); private data (masked); borrow-style-only guidance'],
];
const docChecks = [
  ['mise-config', 'mise project conf.d load order/precedence, file tasks, [tools]/[env], mise trust, activation without global mutation, secret guidance'],
  ['fnox-age', 'jdx/fnox + age: committable encrypted store, age identity kept out of git, get/exec/export, K8s Secret generation with no plaintext on disk, brew install'],
  ['codex-config', 'Codex project .codex/config.toml precedence + the ignored-keys list, CODEX_HOME blocking, launch -c overrides, OTel/full-capture location'],
  ['claude-code-config', 'Claude Code settings precedence/merge, scope-restricted keys, env key, OTel/full-capture vars, ANTHROPIC_* passthrough (set/avoid for subscription OAuth), --settings'],
  ['litellm-core', 'LiteLLM proxy: DB-backed/stateless, virtual keys + key_alias, forward_client_headers_to_llm_api, x-litellm-api-key, local OpenAI-compat routes, langfuse/otel/prometheus callbacks, anti-leak, version pinning'],
  ['litellm-passthrough', 'OpenAI/Codex (native chatgpt/ provider, server-side OAuth, wire_api=responses) vs Anthropic/Claude Max (client-credential forward); header-forward config + the x-litellm-api-key caveat'],
  ['lima-k3s', 'Lima upstream template://k3s (param.url/token, hardcoded INSTALL_K3S_EXEC, agents-not-servers join), 3-server embedded-etcd HA flow, user-v2 reachability, kubeconfig path, sizing'],
  ['cilium-k3s', 'Cilium on k3s prereq flags, pod-CIDR Helm value, kube-proxy KEPT (replacement optional), Hubble + operator HA replicas, Helm OCI install, version, validation'],
  ['langfuse', 'langfuse-k8s chart version, externalize stores via deploy:false, Bitnami-subchart finding + stance, LANGFUSE_INIT_* headless, external-store env, HA + ClickHouse cluster caveat'],
  ['lgtm-stack', 'Grafana/Loki/Tempo/Prometheus/OTel charts (2026 grafana-community relocation), per-component HA mode + storage + retention + Bitnami status, OTel redaction pipeline'],
  ['datastores', 'CloudNativePG (Cluster 3), Altinity ClickHouse (CHI + Keeper), valkey-io chart, SeaweedFS chart — HA recipes, Bitnami-free confirmation, local exceptions'],
  ['homebrew-services', 'brew/tap + brew-services manageability per host tool, mlx-lm via uv, macmon serve, otelcol-contrib tap, TCC/Documents caveat, full Brewfile tool notes'],
  ['chart-selection', 'per-component official-vs-third-party verdict, 6-month maintenance evidence, direct/transitive Bitnami flags + mitigation, CRITICAL escalations'],
];

const researchAgents = [
  ...k8sSource.map(([slug, scope]) => () =>
    agent(
      `${BOUNDARY}\nYou are a SOURCE-REVIEW subagent. Review the "${scope}" area of the private POC at ${K8S}. Extract requirements, reusable patterns, drift to avoid, and scrub concerns for a public Lima-only HA spec. Write the detailed report to ${RESEARCH}/source/${slug}.md`,
      { label: `src:${slug}`, phase: 'Research' })),
  ...dotSource.map(([slug, scope]) => () =>
    agent(
      `${BOUNDARY}\nYou are a SOURCE-REVIEW subagent. Review (STYLE ONLY, no chezmoi/home assumptions) the "${scope}" area of ${DOT}. Write the detailed report to ${RESEARCH}/source/${slug}.md`,
      { label: `src:${slug}`, phase: 'Research' })),
  () =>
    agent(
      `${BOUNDARY}\nYou are a REPO-STATE subagent. Review the current target repo (EXCLUDING its planning/ dir): LICENSE, .claude/, .agents/, .vscode/, skills-lock.json, git remote/owner. Confirm Apache-2.0, the design-doc-mermaid skill provenance (license-compat flag), owner casing, and any publication-safety concerns. Write the report to ${RESEARCH}/validation/repo-state.md`,
      { label: 'src:repo-state', phase: 'Research' }),
  ...docChecks.map(([slug, scope]) => () =>
    agent(
      `${BOUNDARY}\nYou are a DOC-VERIFICATION subagent. Verify CURRENT (the run's month) behavior from PRIMARY docs for: ${scope}. Cite doc URLs. Write your report EARLY/incrementally so a dropped connection does not lose it. Write the detailed report to ${RESEARCH}/docs/${slug}.md`,
      { label: `doc:${slug}`, phase: 'Research' })),
];

// Rate-limit-aware: parallel() respects the runtime's concurrency cap
// (min(16, cores-2)); excess queue automatically. In the real run two agents
// died on transient API/rate-limit errors and were simply re-dispatched — the
// .filter(Boolean) below drops any null (skipped/failed) result so a single
// death does not abort the phase; re-run the workflow with resumeFromRunId to
// fill gaps cheaply.
const research = (await parallel(researchAgents)).filter(Boolean);
log(`Research complete: ${research.length}/${researchAgents.length} reports landed.`);

// ── Phase 2: Synthesize (orchestrator-owned in the real run) ────────────────
// A synthesis agent reconciles every report into ONE decision model and writes
// research/handoff.md (+ keeps research/task-matrix.md current). The
// orchestrator reviews this before drafting; it is the authoritative input the
// spec-writers read.
phase('Synthesize');
await agent(
  `${BOUNDARY}\nYou are the SYNTHESIS subagent. Read every report under ${RESEARCH}/source/, ${RESEARCH}/docs/, and ${RESEARCH}/validation/. Reconcile them against the fixed decisions in the instruction file into ONE internally consistent decision model. Resolve conflicts in favor of the instruction's fixed decisions (e.g. keep kube-proxy/Traefik/ServiceLB even though the POC disabled them; invert POC anonymous-admin and add telemetry redaction; set every bundled Bitnami data subchart deploy:false and externalize). Record the resolved model in ${RESEARCH}/handoff.md and update ${RESEARCH}/task-matrix.md. Return the decision model as a concise summary.`,
  { label: 'synthesize', phase: 'Synthesize' });

// ── Phase 3: Draft (barrier — integration needs all drafts) ─────────────────
// One spec-writer per major area. Each reads handoff.md + its specific reports,
// uses the FINAL section numbers, and writes a polished draft to spec/drafts/.
// W-ARCH owns the canonical repo directory layout that the others anchor to.
phase('Draft');
const writers = [
  ['architecture', 'sections 1,2,3,4,7,18,19,20 — purpose/audience/outcomes, source+pub-safety summary, goals/scope, architecture/topology + Mermaid inventory, canonical repo layout, phased plan, decisions, references. OWNS the canonical directory tree.'],
  ['cluster', 'sections 5,6 — Lima/k3s/Cilium/networking/lifecycle; production-like HA, replica/quorum/PDB/probe policy, stateful reliability, failure injection, resource-escalation, chart policy + no-Bitnami enforcement.'],
  ['host-services', 'sections 8 and 9.1 — project-local mise (conf.d, file tasks), mise task catalog, Brewfile, host services (llama-swap/macmon/OTel via LaunchAgents), bootstrap flow, Mac-side model serving + VM->host bridge.'],
  ['agents', 'sections 9.2-9.6 and 10 — LiteLLM gateway, local routes, the two passthrough mechanisms, model catalog/defaults; Codex + Claude Code project config + launch overrides + agent smoke tests.'],
  ['app-data', 'section 12 — Langfuse web/worker + externalized CNPG/Altinity-ClickHouse/Valkey/SeaweedFS, per-store HA + documented local exceptions, headless bootstrap, runtime Secret rendering.'],
  ['observability', 'section 13 — LGTM components, in-cluster + host OTel collectors, full-capture posture with the redaction boundary, canonical identity/header taxonomy, dashboards/retention, cross-system traceability.'],
  ['secrets-validation-docs', 'sections 11,14,15 — mise non-sensitive env + fnox/age sensitive values + runtime K8s Secret generation + virtual-key policy + scrub guards; README/docs/Mermaid requirements; static/chart/resource validation, pre-commit, smoke + reliability tests.'],
  ['impl-strategy', 'sections 16,17 — full implementation subagent matrix (research/impl/doc-verify/test as independent roles at component/group/dependency/e2e levels), implementation worklog layout, durable markdown task-matrices + handoff + resume procedure + acceptance state.'],
];
const drafts = (await parallel(writers.map(([slug, scope]) => () =>
  agent(
    `${BOUNDARY}\nYou are a SPEC-WRITER subagent for the ai-infra-platform v6 spec. Read ${RESEARCH}/handoff.md fully plus the reports relevant to your area, then draft ${scope} Be DEFINITIVE (no open questions/TBD), use the FINAL spec section numbers/titles, anchor all paths to the canonical repo layout, and keep fixed facts (names, ports, identity, no-Bitnami) consistent. Write the draft to ${SPECDIR}/drafts/${slug}.md`,
    { label: `draft:${slug}`, phase: 'Draft' })
))).filter(Boolean);
log(`Drafts complete: ${drafts.length}/${writers.length}.`);

// ── Phase 4: Integrate ──────────────────────────────────────────────────────
// In the real run THIS WAS DONE BY THE MAIN AGENT with shell tooling, and final
// responsibility was not delegated. Default behavior: stop and hand back.
if (!DELEGATE_INTEGRATION) {
  log(
    'Drafts ready. INTEGRATION IS ORCHESTRATOR-OWNED: assemble ' +
    `${SPECDIR}/drafts/*.md into ${SPEC} with (1) a fence-aware heading ` +
    'normalizer that renumbers headings by dotted depth and strips draft ' +
    'titles/HTML-comments/"Integration Notes", (2) literal-match caption cleanup ' +
    '(remove spec/drafts paths, "guide used", coordination flags), (3) a ToC ' +
    'generated FROM the assembled headings so GitHub anchors always resolve, ' +
    '(4) a synthetic "## 9." parent before 9.1, then (5) Python checks: ToC-link ' +
    'resolution, section order 1..20, fence parity, no-open-questions, ASCII, and ' +
    'a scrub sweep confirming every private-name hit is in guard context only. ' +
    'Then run Phase 5 validation.',
  );
  return { research: research.length, drafts: drafts.length, integrated: false, specPath: SPEC };
}

// OPTIONAL delegated integration (orchestrator must still review the result).
phase('Integrate');
await agent(
  `${BOUNDARY}\nYou are the INTEGRATION subagent (Bash allowed). Assemble ${SPECDIR}/drafts/*.md into the single definitive spec at ${SPEC}. Steps: fence-aware heading normalizer (renumber headings by dotted depth: depth1->##, depth2->###, depth3->####; strip leading draft H1/HTML-comment blocks; truncate at any "Integration Notes" heading; drop standalone image lines and diagram blockquote-meta); assemble sections in order 1..20 (architecture owns 1-4,7,18-20; cluster 5-6; host 8+9.1; agents 9.2-9.6+10; secrets-val 11+14-15; app-data 12; observability 13; impl 16-17) inserting a synthetic "## 9. Model Serving, LiteLLM, and Agent Routing" parent before 9.1; prepend an H1 + lead + "## 0. Table of Contents"; GENERATE the ToC from the actual assembled headings (GitHub anchor algorithm) so links resolve; remove residual draft meta (spec/drafts paths, "guide used", coordination flags); then verify with Python: every in-page ToC link resolves, no duplicate anchors, sections 1..20 present and ordered, fence parity even, no open-questions heading, ASCII outside mermaid fences, and a scrub sweep. Report the final line/word/byte counts and any check failures. Do not consider the file done until all checks pass.`,
  { label: 'integrate', phase: 'Integrate' });

// ── Phase 5: Validate (independent, parallel) ───────────────────────────────
phase('Validate');
const validations = (await parallel([
  () => agent(
    `${BOUNDARY}\nYou are the CONSISTENCY validator. Read ${SPEC} fully. Report (with line numbers) any internal contradictions in fixed facts (node count/sizing/network, k3s flags, kube-proxy/Traefik/ServiceLB kept, pod CIDR, ports, identity taxonomy, admin email, no-Bitnami, the two passthrough mechanisms), heading-numbering gaps, ToC entries not matching headings, directory-path or task/env-name inconsistencies, leftover draft meta, TBD/open-question language, and broken/duplicated Mermaid fences. Give PASS/FAIL per category. Write the report to ${RESEARCH}/validation/consistency.md`,
    { label: 'validate:consistency', phase: 'Validate' }),
  () => agent(
    `${BOUNDARY}\nYou are the PUBLICATION-SAFETY validator. Read ${SPEC} fully. For every sensitive pattern (token shapes, private hosts, internal domains, real emails, real home paths, alternate VM runtime names, deterministic dev-secret families) classify each hit as GUARD_CONTEXT_OK (the spec forbids/masks it) or LEAK (a real value or a private host used as a real default). Confirm the spec requires a working-tree scrub (not .gitignore), gitleaks, rg name-guards, and the design-doc-mermaid upstream license-compat check. Overall PASS only if zero LEAK. Write the report to ${RESEARCH}/validation/publication-safety.md`,
    { label: 'validate:pubsafety', phase: 'Validate' }),
])).filter(Boolean);

return {
  research: research.length,
  drafts: drafts.length,
  integrated: true,
  validations: validations.length,
  specPath: SPEC,
};
