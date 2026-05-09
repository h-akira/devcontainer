#!/bin/bash
# tests/tools.sh — bundled tool availability checks.
#
# Must run as the node user (NOT via sudo). The uv binary lives in
# /home/node/.local/bin, which is on the node user's PATH but not on
# sudo's secure_path — running this under sudo would falsely fail "uv
# is available". Pair with firewall.sh, which covers iptables/ipset/
# dnsmasq state and needs root.
#
# Run inside a running devcontainer:
#
#   /workspace/.devcontainer/tests/tools.sh
#
# Each check is independent. A failure does not stop later checks.

# Note: do NOT set -e here. We want failures to continue.
set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: tools.sh must run as the node user, not root." >&2
    echo "       Running under sudo strips /home/node/.local/bin from PATH" >&2
    echo "       and makes 'uv is available' falsely fail." >&2
    exit 2
fi

PASS=0
FAIL=0
TOTAL=0

# Color output if stdout is a TTY.
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    NC=''
fi

# Run a check that should succeed.
check() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    printf "[%2d] %-60s " "$TOTAL" "$name"
    if "$@" >/dev/null 2>&1; then
        printf "${GREEN}OK${NC}\n"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${NC}\n"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Bundled tool availability checks ==="
echo

check "aws CLI v2.x is available" \
    bash -c "aws --version 2>&1 | grep -q '^aws-cli/2\.'"
check "uv is available" \
    command -v uv
check "node 20.x is available" \
    bash -c "node --version | grep -q '^v20\.'"
check "nvim is available" \
    command -v nvim
check "vim is symlinked to nvim" \
    bash -c "readlink -f /usr/local/bin/vim | grep -q nvim"
check "deno is available" \
    command -v deno
check "tmux is available" \
    command -v tmux

echo
if [ "$FAIL" -eq 0 ]; then
    printf "${GREEN}All %d checks passed.${NC}\n" "$TOTAL"
    exit 0
else
    printf "${RED}%d/%d checks failed.${NC}\n" "$FAIL" "$TOTAL"
    exit 1
fi
