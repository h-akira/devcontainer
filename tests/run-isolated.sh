#!/bin/bash
# tests/run-isolated.sh — build a throwaway devcontainer, run firewall.sh
# inside it, then destroy everything (container + named volumes + tmp workspace).
#
# Use this when you want to verify a change to init-firewall.sh /
# config/dnsmasq/dnsmasq.conf / Dockerfile / devcontainer.json without
# touching whatever container VSCode currently has open.
#
# Requires:
#   - docker (the daemon must be running)
#   - devcontainer CLI:    npm install -g @devcontainers/cli
#   - rsync (preinstalled on macOS / most Linux)
#
# Usage:
#   ./tests/run-isolated.sh                     # default: tear down on exit
#   KEEP_ON_FAILURE=1 ./tests/run-isolated.sh   # keep artifacts if tests fail
#   ./tests/run-isolated.sh --keep-on-failure   # same as the env var above
#
# How it isolates from your current VSCode container:
#   - The throwaway workspace is a fresh mktemp dir, so its devcontainerId
#     hashes differently and Docker named volumes are brand new.
#   - The throwaway container has its own random container name; we identify
#     it by the devcontainer.local_folder label to make sure cleanup only
#     touches what we created.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORKSPACE=""
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"

if [ "${1:-}" = "--keep-on-failure" ]; then
    KEEP_ON_FAILURE=1
fi

cleanup() {
    local rc=$?
    if [ "$KEEP_ON_FAILURE" -eq 1 ] && [ "$rc" -ne 0 ] && [ -n "$TEST_WORKSPACE" ]; then
        echo
        echo "[cleanup] tests failed (exit $rc); KEEP_ON_FAILURE=1 — leaving artifacts:"
        echo "  workspace: $TEST_WORKSPACE"
        local cid
        cid=$(docker ps -aq --filter "label=devcontainer.local_folder=$TEST_WORKSPACE" 2>/dev/null || true)
        if [ -n "$cid" ]; then
            echo "  container: $cid"
            echo "  inspect:   docker exec -u node -it $cid bash"
        fi
        echo "  remove manually when done."
        return
    fi

    echo
    echo "[cleanup] removing throwaway container, volumes, and workspace ..."
    if [ -n "$TEST_WORKSPACE" ]; then
        local cid volumes
        cid=$(docker ps -aq --filter "label=devcontainer.local_folder=$TEST_WORKSPACE" 2>/dev/null || true)
        if [ -n "$cid" ]; then
            volumes=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' $cid 2>/dev/null || true)
            docker rm -f $cid >/dev/null 2>&1 || true
            if [ -n "$volumes" ]; then
                # shellcheck disable=SC2086
                echo $volumes | tr ' ' '\n' | sort -u | xargs -r docker volume rm 2>/dev/null || true
            fi
        fi
        rm -rf "$TEST_WORKSPACE"
    fi
}
trap cleanup EXIT

# --- Pre-flight checks ---
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found in PATH" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker daemon is not reachable. Start Docker Desktop and retry." >&2
    exit 1
fi
if ! command -v devcontainer >/dev/null 2>&1; then
    cat >&2 <<EOM
ERROR: 'devcontainer' CLI not found.
Install with:
  npm install -g @devcontainers/cli
EOM
    exit 1
fi
if ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: rsync not found in PATH" >&2
    exit 1
fi

# --- 1) Materialize a fake "consumer project" that has us as .devcontainer/ ---
TEST_WORKSPACE="$(mktemp -d -t devcontainer-test-XXXXXX)"
echo "[1/4] Throwaway workspace: $TEST_WORKSPACE"
mkdir -p "$TEST_WORKSPACE/.devcontainer"
rsync -a \
    --exclude='.git' \
    --exclude='develop' \
    --exclude='references' \
    --exclude='.claude' \
    --exclude='tmp' \
    "$REPO_ROOT/" "$TEST_WORKSPACE/.devcontainer/"

# --- 2) devcontainer up ---
# `--remove-existing-container` is defensive in case a prior failed run left
# a container with the same labels behind. We are using a fresh tmp workspace
# so this should normally be a no-op.
echo "[2/4] devcontainer up (this triggers a Docker build the first time) ..."
devcontainer up \
    --workspace-folder "$TEST_WORKSPACE" \
    --remove-existing-container

# --- 3) Run firewall.sh (root) and tools.sh (node) inside the container ---
# firewall.sh needs root for iptables/ipset reads; tools.sh must NOT run under
# sudo (sudo's secure_path strips /home/node/.local/bin where uv lives, which
# would falsely fail "uv is available"). Run both, surface the union of
# results so a failure in either is visible.
echo "[3/4] Running /workspace/.devcontainer/tests/firewall.sh (sudo) inside container ..."
devcontainer exec \
    --workspace-folder "$TEST_WORKSPACE" \
    sudo /workspace/.devcontainer/tests/firewall.sh
firewall_rc=$?

echo
echo "[3/4] Running /workspace/.devcontainer/tests/tools.sh (node) inside container ..."
devcontainer exec \
    --workspace-folder "$TEST_WORKSPACE" \
    /workspace/.devcontainer/tests/tools.sh
tools_rc=$?

if [ "$firewall_rc" -ne 0 ] || [ "$tools_rc" -ne 0 ]; then
    test_rc=1
else
    test_rc=0
fi

# --- 4) Done; trap handles cleanup ---
if [ "$test_rc" -eq 0 ]; then
    echo "[4/4] All tests passed."
else
    echo "[4/4] Tests FAILED (firewall.sh exit $firewall_rc, tools.sh exit $tools_rc)." >&2
fi
exit $test_rc
