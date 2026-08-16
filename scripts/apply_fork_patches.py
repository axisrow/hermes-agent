#!/usr/bin/env python3
"""Re-apply this fork's packaging changes on top of upstream Hermes.

This repo is a *repack*, not a fork in the usual sense: no logic is
changed anywhere. The entire delta is a rename — the distribution name,
its self-referential extras, and the console scripts — so the wheel can
be published to PyPI as ``hermes-agent-axisrow`` and coexist with an
upstream Hermes install on the same machine.

That delta is small but positional (line numbers move constantly
upstream, which lands ~100 commits/day), so ``git am`` / ``git
cherry-pick`` of a stored patch breaks on almost every sync. This script
re-derives the changes from the *current* file instead, which is why it
survives upstream churn.

Only ``pyproject.toml`` is touched. Upstream's ``[all]`` extra is kept
as-is, so ``hermes_cli/main.py`` — which defaults its install group to
``"all"`` — needs no patching. Keeping the fork out of the source tree
and out of the docs is deliberate: those are the files upstream rewrites
most often, and every edit there is a merge conflict waiting to happen.

Usage
-----
    git fetch upstream main
    git checkout -B fork-main upstream/main     # take upstream wholesale
    python3 scripts/apply_fork_patches.py       # re-apply fork identity
    uv lock && git commit -am "fork: resync with upstream"

Run with --check to verify without writing (used by CI and by the
publish workflow's guard step).
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

FORK_NAME = "hermes-agent-axisrow"
UPSTREAM_NAME = "hermes-agent"

# console script -> module entrypoint. Renamed so it is unambiguous which
# binary is on $PATH when upstream Hermes is also installed somewhere.
SCRIPT_RENAMES = {
    "hermes": "hermesx",
    "hermes-agent": "hermesx-agent",
    "hermes-acp": "hermesx-acp",
}

ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = ROOT / "pyproject.toml"

# Upstream ships ~27 workflows wired to Nous' own infrastructure (GHCR,
# docs site, release secrets). Six of them trigger on `push`, so leaving
# them in place means every resync push turns the fork's Actions tab red
# for failures that mean nothing here. Only fork-owned workflows survive.
FORK_OWNED_WORKFLOWS = {"publish-fork.yml"}
WORKFLOWS_DIR = ROOT / ".github" / "workflows"


def transform(text: str) -> tuple[str, list[str]]:
    """Return (new_text, list-of-actions-taken)."""
    actions: list[str] = []

    # 1. Distribution name.
    new, n = re.subn(
        rf'^name = "{re.escape(UPSTREAM_NAME)}"$',
        f'name = "{FORK_NAME}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if n:
        actions.append(f"name -> {FORK_NAME}")
    text = new

    # 2. Self-referential extras. Left alone, `pip install <fork>[extra]`
    #    resolves upstream's package from PyPI and installs it alongside
    #    this one; both write agent/, tools/, utils.py to the same paths.
    text, n = re.subn(
        rf'"{re.escape(UPSTREAM_NAME)}\[', f'"{FORK_NAME}[', text
    )
    if n:
        actions.append(f"{n} self-referential extras rewritten")

    # 3. Console scripts, in the [project.scripts] table only.
    for old, new_name in SCRIPT_RENAMES.items():
        text, n = re.subn(
            rf'^{re.escape(old)} = "', f'{new_name} = "', text, count=1,
            flags=re.MULTILINE,
        )
        if n:
            actions.append(f"script {old} -> {new_name}")

    return text, actions


def prune_workflows(dry_run: bool = False) -> list[str]:
    """Delete upstream CI workflows; keep only the fork-owned ones."""
    if not WORKFLOWS_DIR.is_dir():
        return []
    doomed = sorted(
        p for p in WORKFLOWS_DIR.iterdir()
        if p.is_file() and p.name not in FORK_OWNED_WORKFLOWS
    )
    if not dry_run:
        for p in doomed:
            p.unlink()
    return [p.name for p in doomed]


def verify(path: Path) -> list[str]:
    """Return a list of problems; empty means the fork invariants hold."""
    data = tomllib.loads(path.read_text(encoding="utf-8"))["project"]
    problems: list[str] = []

    if data["name"] != FORK_NAME:
        problems.append(f'name is {data["name"]!r}, expected {FORK_NAME!r}')

    extras = data.get("optional-dependencies", {})

    stale = [
        dep
        for deps in extras.values()
        for dep in deps
        if dep.startswith(f"{UPSTREAM_NAME}[")
    ]
    if stale:
        problems.append(f"self-references still pointing upstream: {stale}")

    # A self-reference to an extra upstream has since deleted resolves to
    # nothing *silently*: pip/uv install the base package and skip the
    # unknown extra, so `pip install <fork>[all]` quietly degrades to a
    # bare install. That is exactly how the fork's old `[cli]` reference
    # rotted (uv.lock showed `full -> []`). Fail loudly instead.
    for name, deps in extras.items():
        for dep in deps:
            m = re.fullmatch(rf'{re.escape(FORK_NAME)}\[([^\]]+)\]', dep)
            if not m:
                continue
            for target in (t.strip() for t in m.group(1).split(",")):
                if target and target not in extras:
                    problems.append(
                        f"extra [{name}] references [{target}], "
                        f"which does not exist"
                    )

    scripts = data.get("scripts", {})
    for old in SCRIPT_RENAMES:
        if old in scripts:
            problems.append(f"console script {old!r} not renamed")
    for new_name in SCRIPT_RENAMES.values():
        if new_name not in scripts:
            problems.append(f"console script {new_name!r} missing")

    leftover = [
        p.name for p in WORKFLOWS_DIR.iterdir()
        if p.is_file() and p.name not in FORK_OWNED_WORKFLOWS
    ] if WORKFLOWS_DIR.is_dir() else []
    if leftover:
        problems.append(f"upstream workflows still present: {leftover}")

    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check", action="store_true",
        help="verify only; exit non-zero if the fork invariants are broken",
    )
    args = ap.parse_args()

    if args.check:
        problems = verify(PYPROJECT)
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        if problems:
            return 1
        print(f"OK: {PYPROJECT.name} carries the fork identity")
        return 0

    original = PYPROJECT.read_text(encoding="utf-8")
    updated, actions = transform(original)
    if actions:
        PYPROJECT.write_text(updated, encoding="utf-8")
        for a in actions:
            print(f"  {a}")
    else:
        print(f"{PYPROJECT.name}: nothing to do — fork changes already present")

    pruned = prune_workflows()
    if pruned:
        print(f"  pruned {len(pruned)} upstream workflow(s)")

    problems = verify(PYPROJECT)
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    if problems:
        return 1

    print("\nfork identity applied. Next:")
    print("  uv lock && uv build --wheel")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
