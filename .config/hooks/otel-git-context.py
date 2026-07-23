#!/usr/bin/env python3
"""otel-git-context.py — dynamic VCS correlation records for claude + codex.

Shared PostToolUse hook (Lane D3) invoked by BOTH agent CLIs. Hooks cannot mutate
a span that is already running, so instead of trying to enrich the live session
span this hook APPENDS a self-contained correlation triple — one span, one counter
datapoint, one log record — every time a branch is created or a PR is opened from a
shell tool call. Everything pivots on `session.id`, so the appended records rejoin
the session's other telemetry after the fact.

Signal shape by agent:
  - claude: PostToolUse subprocesses inherit W3C `$TRACEPARENT` (the repo sets
    CLAUDE_CODE_PROPAGATE_TRACEPARENT=1), so the span is emitted as a CHILD of the
    live session trace and carries resource `service.name=claude-code` — the value
    the collector's `filter/langfuse_only_claude_code` requires — so it also reaches
    Langfuse, not just Tempo.
  - codex: no traceparent is passed to hooks (source-confirmed), so a NEW ROOT span
    is emitted keyed by `session.id`; it lands in Tempo and is correlated to the
    gateway trace out-of-band by session id (it is intentionally kept out of the
    claude-only Langfuse pipeline via `service.name=codex`).

Collector endpoint is read from `AI_INFRA_OTEL_VIP` (NOT an `OTEL_*` var — Claude
strips `OTEL_*` from hook subprocesses; `AI_INFRA_OTEL_VIP` survives): OTLP/HTTP JSON
is POSTed to http://$AI_INFRA_OTEL_VIP:4318/v1/{traces,metrics,logs}.

Stdlib only (urllib for OTLP/JSON) so it runs under any python3 with no deps. It
fails SILENTLY and non-fatally — a network/parse error never breaks the tool call;
short per-request timeout; the process always exits 0.

Probe mode: with AI_INFRA_OTEL_GITCTX_PROBE=1 it only records the presence/value of
`$TRACEPARENT` to <repo>/.local/tmp-claude/traceparent-probe.log and exits — used to
confirm Claude actually passes traceparent to hooks before span-join is relied on.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.request

SCOPE = "otel-git-context"
NET_TIMEOUT = 3          # seconds per OTLP POST (fail fast — never block the tool)
GIT_TIMEOUT = 2          # seconds per git subprocess

BRANCH_CREATE_RE = re.compile(r"git\s+(?:checkout\s+-b|switch\s+-c)\s+(\S+)")
PR_CREATE_RE = re.compile(r"\bgh\s+pr\s+create\b")
PR_URL_RE = re.compile(r"/pull/(\d+)")


def _repo_root():
    """Repo root: $CLAUDE_PROJECT_DIR, else `git rev-parse`, else cwd."""
    d = os.environ.get("CLAUDE_PROJECT_DIR")
    if d and os.path.isdir(d):
        return d
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT,
        )
        r = out.stdout.strip()
        if out.returncode == 0 and r:
            return r
    except Exception:
        pass
    return os.getcwd()


def _probe():
    """Lane-D3 probe: log whether $TRACEPARENT reached this hook, then exit 0."""
    try:
        d = os.path.join(_repo_root(), ".local", "tmp-claude")
        os.makedirs(d, exist_ok=True)
        tp = os.environ.get("TRACEPARENT")
        line = "%s\tTRACEPARENT %s\t%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "present" if tp else "absent",
            tp or "",
        )
        with open(os.path.join(d, "traceparent-probe.log"), "a") as f:
            f.write(line)
    except Exception:
        pass
    sys.exit(0)


def _extract_command(tool_input):
    """Pull the shell command text from either agent's tool_input shape."""
    if isinstance(tool_input, dict):
        cmd = tool_input.get("command")
        return cmd if isinstance(cmd, str) else ""
    if isinstance(tool_input, str):
        return tool_input
    return ""


def _collect_text(obj, out, depth=0):
    """Recursively gather string leaves (to scan tool_response for the PR URL)."""
    if depth > 6:
        return
    if isinstance(obj, str):
        out.append(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            _collect_text(v, out, depth + 1)
    elif isinstance(obj, list):
        for v in obj:
            _collect_text(v, out, depth + 1)


def _git(args, cwd):
    try:
        out = subprocess.run(
            ["git"] + args, capture_output=True, text=True,
            timeout=GIT_TIMEOUT, cwd=cwd,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def _repo_name(cwd):
    """Remote-slug (strip .git) with a toplevel-basename fallback."""
    url = _git(["config", "--get", "remote.origin.url"], cwd)
    if url:
        slug = url.rstrip("/").split("/")[-1]
        if slug.endswith(".git"):
            slug = slug[:-4]
        if slug:
            return slug
    try:
        return os.path.basename(cwd.rstrip("/")) or "unknown"
    except Exception:
        return "unknown"


def _head_branch(cwd):
    b = _git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)
    return b if b and b != "HEAD" else None


def _attr(k, v):
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}  # int64 -> string in OTLP/JSON
    return {"key": k, "value": {"stringValue": str(v)}}


def _attrs(d):
    return [_attr(k, v) for k, v in d.items() if v is not None and v != ""]


def _parse_traceparent(tp):
    """W3C `00-<32hex trace>-<16hex span>-<2hex flags>` -> (trace, span, flags)."""
    try:
        parts = tp.strip().split("-")
        if len(parts) >= 4 and len(parts[1]) == 32 and len(parts[2]) == 16:
            return parts[1], parts[2], int(parts[3], 16)
    except Exception:
        pass
    return None


def _post(url, payload):
    try:
        req = urllib.request.Request(
            url, data=json.dumps(payload).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as resp:
            resp.read()
    except Exception:
        pass  # fail silently — telemetry loss must never break the tool call


def main():
    if os.environ.get("AI_INFRA_OTEL_GITCTX_PROBE") == "1":
        _probe()  # exits

    raw = sys.stdin.read()
    if not raw:
        return
    data = json.loads(raw)
    if not isinstance(data, dict):
        return

    command = _extract_command(data.get("tool_input"))
    # Gate: only shell/Bash tool calls carrying a command string. Both CLIs name the
    # shell tool differently (claude "Bash"; codex "shell"/"local_shell"), and the
    # branch/PR regexes below are the real gate, so keying on the command payload is
    # sufficient and shape-tolerant.
    if not command:
        return

    event = None
    branch_from_cmd = None
    m = BRANCH_CREATE_RE.search(command)
    if m:
        event = "branch_created"
        branch_from_cmd = m.group(1).strip().strip("'").strip('"')
    elif PR_CREATE_RE.search(command):
        event = "pr_created"
    if not event:
        return

    cwd = _repo_root()
    session_id = data.get("session_id") or data.get("sessionId") or ""

    pr_number = None
    if event == "pr_created":
        parts = []
        _collect_text(data.get("tool_response"), parts)
        mm = PR_URL_RE.search("\n".join(parts))
        if mm:
            try:
                pr_number = int(mm.group(1))
            except Exception:
                pr_number = None

    head = branch_from_cmd if event == "branch_created" else None
    if not head:
        head = _head_branch(cwd)

    # Agent + span topology hinge on inherited traceparent (see module docstring).
    tp = os.environ.get("TRACEPARENT", "")
    parsed = _parse_traceparent(tp) if tp else None
    if parsed:
        agent, service_name = "claude", "claude-code"
    else:
        agent, service_name = "codex", "codex"

    common = {
        "session.id": session_id,
        "vcs.repository.name": _repo_name(cwd),
        # Canonical branch key: SAME `vcs.branch.name` used by the session-start resource
        # attrs (10-env.toml OTEL_RESOURCE_ATTRIBUTES exec, smoke.sh assertion, taxonomy §1),
        # so ONE LogQL/TraceQL/PromQL selector matches both the session telemetry and these
        # correlation records. (Was `vcs.ref.head.name`; standardized per review finding.)
        "vcs.branch.name": head,
        "vcs.pr.number": pr_number,
        "event": event,
        "agent": agent,
    }
    resource_attrs = [_attr("service.name", service_name)] + _attrs(common)
    dp_attrs = _attrs(common)

    vip = os.environ.get("AI_INFRA_OTEL_VIP")
    if not vip:
        return
    base = "http://%s:4318" % vip

    now = time.time_ns()

    span = {
        "name": "git." + event,
        "kind": 1,  # SPAN_KIND_INTERNAL
        "startTimeUnixNano": str(now),
        "endTimeUnixNano": str(now),
        "spanId": os.urandom(8).hex(),
        "attributes": dp_attrs,
    }
    if parsed:
        trace_id, parent_span_id, flags = parsed
        span["traceId"] = trace_id           # child of the live session trace
        span["parentSpanId"] = parent_span_id
        span["flags"] = flags
    else:
        span["traceId"] = os.urandom(16).hex()  # new root correlation trace (codex)
    traces = {"resourceSpans": [{
        "resource": {"attributes": resource_attrs},
        "scopeSpans": [{"scope": {"name": SCOPE}, "spans": [span]}],
    }]}

    metrics = {"resourceMetrics": [{
        "resource": {"attributes": resource_attrs},
        "scopeMetrics": [{"scope": {"name": SCOPE}, "metrics": [{
            "name": "agent.git.event",
            "unit": "1",
            "sum": {
                "dataPoints": [{
                    "asInt": "1",
                    "startTimeUnixNano": str(now),
                    "timeUnixNano": str(now),
                    "attributes": dp_attrs,
                }],
                "aggregationTemporality": 1,  # DELTA (one-shot event)
                "isMonotonic": True,
            },
        }]}],
    }]}

    body = "%s %s: repo=%s branch=%s pr=%s session=%s" % (
        agent, event, common["vcs.repository.name"], head or "",
        pr_number if pr_number is not None else "", session_id or "",
    )
    logs = {"resourceLogs": [{
        "resource": {"attributes": resource_attrs},
        "scopeLogs": [{"scope": {"name": SCOPE}, "logRecords": [{
            "timeUnixNano": str(now),
            "observedTimeUnixNano": str(now),
            "severityNumber": 9,  # INFO
            "severityText": "INFO",
            "body": {"stringValue": body},
            "attributes": dp_attrs,
        }]}],
    }]}

    _post(base + "/v1/traces", traces)
    _post(base + "/v1/metrics", metrics)
    _post(base + "/v1/logs", logs)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never surface a hook failure to the tool call
    sys.exit(0)
