#!/usr/bin/env bash
#
# Fork-owned local release script for `hermes-agent-axisrow`.
#
# The primary publish path is GitHub Actions (.github/workflows/publish-fork.yml,
# OIDC trusted publishing on a `v*` tag push). This script is the manual
# fallback — same token-based release_pypi.sh pattern used across the other
# axisrow projects (direct-cli, tg_content_factory, tg_messenger, ...), kept
# here purely for local/offline releases.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
PYPROJECT="${ROOT_DIR}/pyproject.toml"

usage() {
  cat <<'EOF'
Usage:
  scripts/release_pypi.sh testpypi
  scripts/release_pypi.sh pypi
  scripts/release_pypi.sh all

Behavior:
  - loads .env from the repository root when present
  - derives the package version from the current git tag (vX.Y.Z[.N]),
    same rule as the CI publish workflow — pyproject.toml's own `version`
    is upstream's and gets clobbered on every resync, so it is never used
  - patches pyproject.toml's version in place for the build, then restores
    the original file afterward (upstream file, never committed dirty)
  - rebuilds dist artifacts from scratch
  - runs twine checks before upload
  - uploads to TestPyPI, PyPI, or both

Required .env variables:
  TWINE_USERNAME=__token__
  TEST_PYPI_TOKEN=pypi-...   # for testpypi/all
  PYPI_TOKEN=pypi-...        # for pypi/all
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET="$1"

case "${TARGET}" in
  testpypi|pypi|all)
    ;;
  *)
    usage
    exit 1
    ;;
esac

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

TWINE_USERNAME="${TWINE_USERNAME:-__token__}"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "Required command not found: ${name}" >&2
    exit 1
  fi
}

resolve_version() {
  local tag
  tag="$(cd "${ROOT_DIR}" && git describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ -z "${tag}" ]]; then
    echo "HEAD is not tagged. Tag the release first:" >&2
    echo "  git tag vX.Y.Z.N && git push origin vX.Y.Z.N" >&2
    exit 1
  fi
  local version="${tag#v}"
  if [[ ! "${version}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Tag '${tag}' does not yield a valid PEP 440 version: '${version}'" >&2
    exit 1
  fi
  echo "${version}"
}

restore_pyproject() {
  (cd "${ROOT_DIR}" && git checkout -- pyproject.toml) 2>/dev/null || true
}

build_artifacts() {
  require_command python3
  require_command uv

  local version
  version="$(resolve_version)"
  echo "package version -> ${version} (from git tag)"

  trap restore_pyproject EXIT
  sed -i.bak "s/^version = \".*\"/version = \"${version}\"/" "${PYPROJECT}"
  rm -f "${PYPROJECT}.bak"

  echo "Cleaning old build artifacts"
  rm -rf "${ROOT_DIR}/dist" "${ROOT_DIR}/build" "${ROOT_DIR}"/*.egg-info

  echo "Building package"
  (
    cd "${ROOT_DIR}"
    # uv build, not `python -m build --no-isolation`: build-system.requires
    # pins setuptools==83.0.0 exactly, which --no-isolation cannot guarantee
    # against whatever setuptools happens to be on PATH. uv build resolves
    # an isolated build env matching the pin, same as the CI workflow.
    #
    # setup.py blocks bdist_wheel/sdist outside a Nix build (upstream's own
    # escape hatch, see setup.py). Intentional here: package-data never
    # included skills/optional-skills/optional-mcps/locales (TUI/CLI-only
    # assets), so the resulting wheel is the intended minimal library.
    HERMES_NIX_BUILD=1 uv build --sdist --wheel
  )

  echo "Checking artifacts with twine"
  (
    cd "${ROOT_DIR}"
    python3 -m twine check dist/*
  )
}

upload_target() {
  local repository="$1"
  local password_var="$2"

  require_var "${password_var}"

  echo "Uploading to ${repository}"
  (
    cd "${ROOT_DIR}"
    TWINE_USERNAME="${TWINE_USERNAME}" \
    TWINE_PASSWORD="${!password_var}" \
    python3 -m twine upload --non-interactive --skip-existing --repository "${repository}" dist/*
  )
}

build_artifacts

case "${TARGET}" in
  testpypi)
    upload_target "testpypi" "TEST_PYPI_TOKEN"
    ;;
  pypi)
    upload_target "pypi" "PYPI_TOKEN"
    ;;
  all)
    upload_target "testpypi" "TEST_PYPI_TOKEN"
    upload_target "pypi" "PYPI_TOKEN"
    ;;
esac
