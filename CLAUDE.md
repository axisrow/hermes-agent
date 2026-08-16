# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **repack of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)** (the self-improving AI agent). This is not a fork in the usual sense — **no logic is changed anywhere**. The entire delta is a rename (distribution name, self-referential extras, console scripts) plus a few fork-only files. The bulk of the code (agent loop, tools, gateway, CLI, TUI) is upstream Hermes and is documented exhaustively in **`AGENTS.md`** — read that file for the deep architecture (AIAgent loop, tool-discovery chain, CLI/TUI/gateway, skills, plugins, config). This file covers only the fork-specific delta.

The fork's purpose: install Hermes as a **library** (`hermes-agent-axisrow`) and drive it from consumer projects via a thin wrapper, with two interchangeable auth paths (ChatGPT/Codex subscription, or a metered `OPENAI_API_KEY`).

**Design rule: never edit upstream's source or docs.** Upstream lands ~100 commits/day and rewrites exactly those files, so every edit there is a merge conflict on the next resync. The fork keeps `[all]` as upstream ships it (which is why `hermes_cli/main.py`, defaulting its install group to `"all"`, needs no patch) and confines the delta to `pyproject.toml` + files upstream doesn't have.

## Fork identity (load-bearing)

The fork renames the distribution and console scripts so it can coexist with an upstream Hermes install on the same machine:

- Distribution: `hermes-agent` → **`hermes-agent-axisrow`**
- Console scripts: `hermes` → **`hermesx`**, `hermes-agent` → **`hermesx-agent`**, `hermes-acp` → **`hermesx-acp`**
- Self-referential extras (`hermes-agent[all]` → `hermes-agent-axisrow[all]`) are rewritten so `pip install <fork>[all]` doesn't pull upstream's package from PyPI.

These changes live in `pyproject.toml` and are **re-derived, not stored as a patch** — see `scripts/apply_fork_patches.py`.

The script also **prunes `.github/workflows/`** down to fork-owned files (`publish-fork.yml`). Upstream's ~28 workflows target Nous' own infrastructure (GHCR, docs site, release secrets); six trigger on `push`, so leaving them in place turns the fork's Actions tab red on every resync.

## Resyncing with upstream

Upstream moves constantly (~100 commits/day) and line numbers shift, so a stored patch breaks on every sync. `scripts/apply_fork_patches.py` re-derives the fork identity from the *current* `pyproject.toml` instead:

```bash
git fetch upstream main
git checkout -B fork-main upstream/main     # take upstream wholesale
python3 scripts/apply_fork_patches.py       # re-apply fork identity
uv lock && git commit -am "fork: resync with upstream"
```

The branch is **recreated, not merged**, and the whole delta is derived from whatever upstream currently looks like — so conflicts are impossible by construction.

`python3 scripts/apply_fork_patches.py --check` verifies the invariants without writing. If it fails, the fork identity is broken — fix before committing. The transforms are idempotent — re-running on an already-patched file is a no-op.

**Extras are left exactly as upstream ships them.** The fork previously carried its own `min`/`full` profiles pointing at `[cli]`; upstream later moved `prompt_toolkit`/`rich`/`fire` into base dependencies and deleted `[cli]`, which silently emptied both profiles (`uv.lock` showed `full -> []`, so `pip install <fork>[full]` installed nothing extra). `verify()` now fails when a self-reference points at a non-existent extra, so that class of silent rot is caught.

**Releases:** build from upstream *tags*, not from the moving `main`, or releases aren't reproducible.

## The consumer wrapper

`scripts/fork_client_example.py` is the fork's main deliverable. It's meant to be **copied into a consumer project** (not imported from here) and hides the difference between the two access paths:

```python
from fork_client_example import ask
ask("...")                          # ChatGPT/Codex subscription (default)
ask("...", auth="api_key")          # metered OPENAI_API_KEY
```

- **Subscription path** (`auth="subscription"`): resolves tokens via `hermes_cli.auth.resolve_codex_runtime_credentials()`, which auto-refreshes the access token from the stored refresh token. Requires a one-time `hermesx auth login openai-codex`. Drives the agent with `provider="openai-codex"` / `api_mode="codex_responses"` against `https://chatgpt.com/backend-api/codex`.
- **Model choice is load-bearing**: `gpt-5.1-codex` is rejected with HTTP 400 ("not supported when using Codex with a ChatGPT account"). Defaults to `gpt-5.6-luna` (what the local Codex CLI is configured with). The API-key path defaults to `gpt-4o-mini`.
- `make_agent()` passes `enabled_toolsets=[]`, `skip_context_files`, `skip_memory`, `quiet_mode` to strip Hermes' context-file/memory/stdout machinery, leaving a clean "request → tool calls → response" loop.

**Installation caveat:** Hermes occupies very generic top-level names (`agent`, `tools`, `providers`, `utils`, `cli`). A consumer project's own `utils.py` breaks Hermes' imports. Default install is **isolated**:

```bash
uv tool install git+https://github.com/axisrow/hermes-agent@fork-main
```

and call it as an external process (`hermesx-agent`). Direct import (as in the wrapper) only works when the consumer project has no modules with those names.

## Build, test, develop

```bash
# Setup (uv + Python 3.11 venv + editable install)
./setup-hermes.sh                       # or manually:
uv venv .venv --python 3.11 && source .venv/bin/activate
uv pip install -e ".[all]"              # or bare "." — CLI deps are in base

# Tests — ALWAYS use the canonical runner, not bare pytest
scripts/run_tests.sh                    # full suite
scripts/run_tests.sh tests/agent/       # discover only here
scripts/run_tests.sh tests/foo.py       # single file
scripts/run_tests.sh tests/foo.py -- --tb=long   # path + pytest args

# Build / lock
uv lock && uv build --wheel
```

`scripts/run_tests.sh` enforces per-file subprocess isolation (via `scripts/run_tests_parallel.py`), a hermetic env (`TZ=UTC`, `LANG=C.UTF-8`, `PYTHONHASHSEED=0`, blanked credentials), and probes `.venv` → `venv` → `$HOME/.hermes/hermes-agent/venv`. Run it instead of calling `pytest` directly so your local run matches CI.

## Key constraints

- **`requires-python = ">=3.11,<3.14"`** — the `<3.14` ceiling is load-bearing: Rust-backed transitives (e.g. `pydantic-core`) have no cp314 wheels yet, and uv would otherwise attempt a failing maturin source build. Don't raise it until those ship cp314 wheels.
- **Dependencies are exact-pinned (`==X.Y.Z`)** — no ranges. When updating a pin, regenerate `uv.lock` with `uv lock`. Only packages used by *every* session belong in `dependencies`; provider-specific ones go in extras and are lazy-installed via `tools/lazy_deps.py`.
- **Never hardcode `~/.hermes` paths** — use `get_hermes_home()` from `hermes_constants.py` (profile-aware). See AGENTS.md "Known Pitfalls" for more.
