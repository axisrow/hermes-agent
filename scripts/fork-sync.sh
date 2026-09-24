#!/usr/bin/env bash
# fork-sync.sh — mechanical fork sync for axisrow/hermes-agent.
#
# Rebuilds `fork-main` = current upstream/main tip + re-applied packaging
# deltas (distribution rename hermes-agent -> hermes-agent-axisrow,
# hermesx* console scripts, extras self-references, fork publish workflow),
# using git plumbing only — no working-tree checkout, no big pack fetches.
#
# The script commits ITSELF as scripts/fork-sync.sh so it travels with the
# branch and the next sync is one command.
#
# Usage:
#   bash fork-sync.sh          # local: build the commit, move refs, verify
#   bash fork-sync.sh --push   # also push fork-main to origin
set -euo pipefail

REPO=/Users/axisrow/Projects/hermes-agent
WORK=/tmp/sync
OLD_FORK_MAIN=b3adbabdb   # June 2026 packaging commit (publish-fork.yml source)
PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

log() { printf '\n=== %s ===\n' "$*"; }
g() { git -C "$REPO" "$@"; }

retry() { # retry <attempts> <sleep_s> <cmd...> — network drops mid-transfer
    local n=$1 s=$2; shift 2
    local k
    for k in $(seq 1 "$n"); do
        if "$@"; then return 0; fi
        echo "  attempt $k/$n failed, retry in ${s}s" >&2
        [ "$k" -lt "$n" ] && sleep "$s"
    done
    return 1
}

log "1. fetch upstream tip (blob:none, shallow)"
retry 5 10 g fetch --filter=blob:none --depth=1 upstream main
TIP=$(g rev-parse upstream/main)
echo "tip = $TIP"

log "2. extract tip blobs + fork-only files"
mkdir -p "$WORK"
catfile_retry() { local out=$1 spec=$2; retry 5 5 g cat-file blob "$spec" > "$out"; }
catfile_retry "$WORK/pyproject.toml"    upstream/main:pyproject.toml
catfile_retry "$WORK/uv.lock"           upstream/main:uv.lock
catfile_retry "$WORK/gitignore"         upstream/main:.gitignore
g show "$OLD_FORK_MAIN:.github/workflows/publish-fork.yml" > "$WORK/publish-fork.yml"
cp "$0" "$WORK/fork-sync.sh"

log "3. transforms"
python3 - "$WORK" <<'PY'
import sys, pathlib, tomllib

w = pathlib.Path(sys.argv[1])

# --- pyproject.toml: distribution name, extras self-references, scripts ---
p = w / 'pyproject.toml'
s = p.read_text()
s = s.replace('name = "hermes-agent"', 'name = "hermes-agent-axisrow"', 1)
s = s.replace('"hermes-agent[', '"hermes-agent-axisrow[')
s = s.replace('hermes = "hermes_cli.main:main"', 'hermesx = "hermes_cli.main:main"')
s = s.replace('hermes-agent = "agent.legacy_cli:main"', 'hermesx-agent = "agent.legacy_cli:main"')
s = s.replace('hermes-acp = "acp_adapter.entry:main"', 'hermesx-acp = "acp_adapter.entry:main"')

# any console script upstream adds under [project.scripts] that starts with
# `hermes` gets the hermesx prefix too; nothing outside that section moves.
sec, out = None, []
for ln in s.splitlines(True):
    st = ln.strip()
    if st.startswith('['):
        sec = st
    if sec == '[project.scripts]' and ln.startswith('hermes') and not ln.startswith('hermesx'):
        ln = 'hermesx' + ln[6:]
    out.append(ln)
s = ''.join(out)
assert 'name = "hermes-agent"' not in s, 'unrenamed distribution name'
assert '"hermes-agent[' not in s, 'unrenamed extras self-reference'
tomllib.loads(s)  # must stay valid TOML
p.write_text(s)

# --- uv.lock: root package name + extras self-reference entries ---
lk = w / 'uv.lock'
s = lk.read_text().replace('name = "hermes-agent"', 'name = "hermes-agent-axisrow"')
assert '"hermes-agent"' not in s, 'unrenamed lock entry'
lk.write_text(s)

# --- .gitignore: fork egg-info dir ---
gi = w / 'gitignore'
s = gi.read_text()
if 'hermes_agent_axisrow.egg-info/' not in s:
    s = s.replace('hermes_agent.egg-info/',
                  'hermes_agent.egg-info/\nhermes_agent_axisrow.egg-info/', 1)
assert 'hermes_agent_axisrow.egg-info/' in s
gi.write_text(s)

pf = w / 'publish-fork.yml'
assert 'hermes-agent-axisrow' in pf.read_text(), 'publish workflow lost its package name'
print('transforms OK')
PY

log "4. plumbing: tree + commit (no checkout)"
B_PY=$(g hash-object -w "$WORK/pyproject.toml")
B_LOCK=$(g hash-object -w "$WORK/uv.lock")
B_GI=$(g hash-object -w "$WORK/gitignore")
B_PF=$(g hash-object -w "$WORK/publish-fork.yml")
B_SH=$(g hash-object -w "$WORK/fork-sync.sh")

# Per-level mktree: flat ls-tree listings never touch missing blobs, and
# --missing tolerates the tip's unbloomed entries. (write-tree would try to
# lazy-fetch every index blob and dies on this network.)
g ls-tree upstream/main > "$WORK/root.txt"
g ls-tree "upstream/main:.github" > "$WORK/gh.txt"
g ls-tree "upstream/main:.github/workflows" > "$WORK/wf.txt"
g ls-tree "upstream/main:scripts" > "$WORK/scripts.txt" || true

python3 - "$WORK" "$B_PY" "$B_LOCK" "$B_GI" "$B_PF" "$B_SH" <<'PY'
import sys, pathlib

w = pathlib.Path(sys.argv[1])
b_py, b_lock, b_gi, b_pf, b_sh = sys.argv[2:7]

def patch(src, dst, repl, add):
    lines = pathlib.Path(w / src).read_text().splitlines(True)
    seen = set()
    out = []
    for ln in lines:
        meta, path = ln.split('\t', 1)
        path = path.rstrip('\n')
        if path in repl:
            mode, _, _rest = meta.partition(' ')
            meta = f'{mode} blob {repl[path]}'
            seen.add(path)
        out.append(meta + '\t' + path + '\n')
    for path, sha in add.items():
        if path not in seen:
            out.append(f'100644 blob {sha}\t{path}\n')
    pathlib.Path(w / dst).write_text(''.join(out))

# flat subtree listings: + publish-fork.yml, + fork-sync.sh
patch('wf.txt', 'wf.final.txt', {'publish-fork.yml': b_pf}, {'publish-fork.yml': b_pf})
patch('scripts.txt', 'scripts.final.txt', {}, {'fork-sync.sh': b_sh})

# .github: swap the `workflows` entry for the rebuilt subtree -> T_WF
gh_out = []
for ln in (w / 'gh.txt').read_text().splitlines(True):
    meta, path = ln.split('\t', 1)
    if path.rstrip('\n') == 'workflows':
        ln = f'040000 tree {{WF}}\tworkflows\n'
    gh_out.append(ln)
(w / 'gh.final.txt').write_text(''.join(gh_out))

# root: swap the three blobs; point .github at T_GH and scripts at T_SC
root_lines = pathlib.Path(w / 'root.txt').read_text().splitlines(True)
out = []
for ln in root_lines:
    meta, path = ln.split('\t', 1)
    path = path.rstrip('\n')
    if path == 'pyproject.toml':
        ln = f'100644 blob {b_py}\tpyproject.toml\n'
    elif path == 'uv.lock':
        ln = f'100644 blob {b_lock}\tuv.lock\n'
    elif path == '.gitignore':
        ln = f'100644 blob {b_gi}\t.gitignore\n'
    elif path == '.github':
        ln = f'040000 tree {{GH}}\t.github\n'
    elif path == 'scripts':
        ln = f'040000 tree {{SC}}\tscripts\n'
    out.append(ln)
(w / 'root.final.txt').write_text(''.join(out))
print('tree listings patched')
PY

T_WF=$(g mktree --missing < "$WORK/wf.final.txt")
sed -i '' "s/{WF}/$T_WF/" "$WORK/gh.final.txt"
T_GH=$(g mktree --missing < "$WORK/gh.final.txt")
T_SC=$(g mktree --missing < "$WORK/scripts.final.txt")
sed -i '' -e "s/{GH}/$T_GH/" -e "s/{SC}/$T_SC/" "$WORK/root.final.txt"
T_ROOT=$(g mktree --missing < "$WORK/root.final.txt")
NEW=$(g commit-tree "$T_ROOT" -p "$TIP" -m "fork: rebase packaging layer onto upstream main

Re-applies the axisrow packaging deltas (distribution rename to
hermes-agent-axisrow, hermesx* entry points, extras self-references,
fork publish workflow, sync script) onto the current upstream main tip.
See scripts/fork-sync.sh — the sync is now one mechanical command.")

echo "new commit = $NEW"

log "5. verify"
for f in gh.final.txt scripts.final.txt root.final.txt; do
    names=$(grep -oE $'\t[^\t]+$' "$WORK/$f" | sort | uniq -d)
    if [ -n "$names" ]; then echo "DUPLICATE tree entries in $f: $names" >&2; exit 1; fi
done
FILES=$(g diff --name-only "$TIP" "$NEW" | sort | paste -sd, -)
EXPECT=$'.github/workflows/publish-fork.yml,.gitignore,pyproject.toml,scripts/fork-sync.sh,uv.lock'
if [ "$FILES" != "$EXPECT" ]; then
    echo "UNEXPECTED FILE SET: $FILES" >&2
    exit 1
fi
echo "changed files: $FILES"

log "6. refs (archive old fork-main, move fork-main)"
if ! g rev-parse -q --verify refs/heads/fork-main-june >/dev/null; then
    g update-ref refs/heads/fork-main-june "$OLD_FORK_MAIN"
fi
g update-ref refs/heads/fork-main "$NEW"
echo "fork-main       -> $(g rev-parse refs/heads/fork-main)"
echo "fork-main-june  -> $(g rev-parse refs/heads/fork-main-june)"

if [ "$PUSH" = 1 ]; then
    log "7. push"
    # Fork shares the object store with upstream: expose the tip as a ref on
    # origin first (no transfer), so push negotiation uploads only our few
    # new blobs instead of 3.5 months of upstream objects.
    if gh api "repos/axisrow/hermes-agent/git/refs/heads/upstream-sync-tip" >/dev/null 2>&1; then
        gh api -X PATCH "repos/axisrow/hermes-agent/git/refs/heads/upstream-sync-tip" \
            -f "sha=$TIP" -F force=true >/dev/null
    else
        gh api -X POST "repos/axisrow/hermes-agent/git/refs" \
            -f "ref=refs/heads/upstream-sync-tip" -f "sha=$TIP" >/dev/null
    fi
    g fetch --filter=blob:none --depth=1 origin upstream-sync-tip
    if g ls-remote --exit-code --heads origin refs/heads/fork-main >/dev/null 2>&1; then
        g push origin "$NEW:refs/heads/fork-main" --force-with-lease="refs/heads/fork-main:$OLD_FORK_MAIN"
    else
        g push origin "$NEW:refs/heads/fork-main"
    fi
    echo "pushed."
else
    log "7. push skipped (run with --push)"
fi

log "done"
