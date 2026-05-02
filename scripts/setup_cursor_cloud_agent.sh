#!/usr/bin/env bash
# Prepare a Cursor Cloud Agent checkout for hermes-agent development.
#
# This script is intentionally non-interactive and idempotent so it can be used
# as a Cursor environment setup command. It installs the system/runtime pieces
# that are commonly missing from fresh cloud images, then pre-warms the Python
# and Node dependency graphs used by tests and builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${HERMES_CLOUD_PYTHON_BIN:-python3.12}"
VENV_DIR="${HERMES_CLOUD_VENV_DIR:-$REPO_ROOT/venv}"
NODE_TARGET_MAJOR="${HERMES_NODE_TARGET_MAJOR:-22}"

log() {
  printf '==> %s\n' "$*"
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    printf 'error: root privileges or sudo are required for: %s\n' "$*" >&2
    return 1
  fi
}

install_apt_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get not found; skipping Debian/Ubuntu system package install"
    return 0
  fi

  log "Installing system dependencies"
  export DEBIAN_FRONTEND=noninteractive
  run_as_root apt-get update
  run_as_root apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    pkg-config \
    libffi-dev \
    ripgrep \
    ffmpeg \
    python3.12 \
    python3.12-dev \
    python3.12-venv
}

ensure_python_venv() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    printf 'error: %s is not available after system dependency setup\n' "$PYTHON_BIN" >&2
    return 1
  fi

  if [ -x "$VENV_DIR/bin/python" ]; then
    local existing_version
    existing_version="$("$VENV_DIR/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if [ "$existing_version" != "3.12" ]; then
      log "Removing $VENV_DIR because it uses Python $existing_version"
      rm -rf "$VENV_DIR"
    fi
  fi

  if [ ! -x "$VENV_DIR/bin/python" ]; then
    log "Creating Python virtualenv at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi

  log "Installing Python packaging tools and uv"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel uv

  log "Syncing Python dependencies from uv.lock"
  UV_PROJECT_ENVIRONMENT="$VENV_DIR" "$VENV_DIR/bin/uv" sync --all-extras --locked

  log "Pre-installing pytest-split for scripts/run_tests.sh"
  "$VENV_DIR/bin/python" -m pip install --upgrade "pytest-split>=0.9,<1"
}

ensure_node_runtime() {
  log "Ensuring Node.js $NODE_TARGET_MAJOR and npm are available"
  export HERMES_NODE_TARGET_MAJOR="$NODE_TARGET_MAJOR"
  export HERMES_NODE_MIN_VERSION=20

  # shellcheck source=scripts/lib/node-bootstrap.sh
  source "$REPO_ROOT/scripts/lib/node-bootstrap.sh"
  ensure_node

  if [ "${HERMES_NODE_AVAILABLE:-false}" != true ]; then
    printf 'error: failed to install or activate Node.js %s\n' "$NODE_TARGET_MAJOR" >&2
    return 1
  fi

  node --version
  npm --version
}

install_node_dependencies() {
  log "Installing root Node dependencies"
  (cd "$REPO_ROOT" && npm ci)

  log "Installing and building ui-tui"
  (cd "$REPO_ROOT/ui-tui" && npm ci && npm run build)
}

main() {
  cd "$REPO_ROOT"
  install_apt_dependencies
  ensure_node_runtime
  ensure_python_venv
  install_node_dependencies

  log "Cursor Cloud Agent environment is ready"
  log "Run Python tests with: scripts/run_tests.sh"
}

main "$@"
