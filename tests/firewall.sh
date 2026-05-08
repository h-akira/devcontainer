#!/bin/bash
# tests/firewall.sh — DNS-filter firewall acceptance tests.
#
# Run inside a running devcontainer (the firewall must already be set up by
# init-firewall.sh, which happens automatically at postStartCommand):
#
#   sudo /workspace/.devcontainer/tests/firewall.sh
#
# Each check is independent. A failure does not stop later checks, so the
# final summary lists every problem currently visible.

# Note: do NOT set -e here. We want failures to continue.
set -uo pipefail

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

# Run a check that should FAIL (i.e. the firewall should block it).
check_blocked() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    printf "[%2d] %-60s " "$TOTAL" "$name"
    if ! "$@" >/dev/null 2>&1; then
        printf "${GREEN}OK${NC}\n"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${NC}\n"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== DNS-filter firewall acceptance tests ==="
echo

# --- Process & config state ---
check "dnsmasq is running" \
    pgrep -x dnsmasq
check "ipset 'allowed-domains' exists" \
    ipset list allowed-domains
check "/etc/resolv.conf points at 127.0.0.1" \
    bash -c "grep -q '^nameserver 127\.0\.0\.1$' /etc/resolv.conf"

# --- Allowed domains resolve and connect ---
check "api.github.com resolves via dnsmasq" \
    bash -c "host -W 5 api.github.com 127.0.0.1"
check "api.github.com is reachable" \
    curl --connect-timeout 10 -sS https://api.github.com/zen -o /dev/null
check "sts.amazonaws.com is reachable (suffix match)" \
    curl --connect-timeout 10 -sS -o /dev/null https://sts.amazonaws.com/
check "pypi.org is reachable" \
    curl --connect-timeout 10 -sS -o /dev/null https://pypi.org/
check "registry.npmjs.org is reachable" \
    curl --connect-timeout 10 -sS -o /dev/null https://registry.npmjs.org/
check "deb.debian.org is reachable (was Fastly-CDN-rotation flaky pre-PoC)" \
    curl --connect-timeout 10 -sS -o /dev/null http://deb.debian.org/debian/

# --- Blocked domains (dnsmasq returns NXDOMAIN) ---
check_blocked "example.com is NOT resolvable" \
    bash -c "host -W 5 example.com 127.0.0.1 | grep -q 'has address'"
check_blocked "example.com is NOT reachable" \
    curl --connect-timeout 5 -sS https://example.com -o /dev/null
check_blocked "reddit.com is NOT reachable (Fastly-fronted but not allowlisted)" \
    curl --connect-timeout 5 -sS https://reddit.com -o /dev/null
check_blocked "wikipedia.org is NOT reachable" \
    curl --connect-timeout 5 -sS https://wikipedia.org -o /dev/null

# --- IP-direct attack ---
check_blocked "direct connect to a non-allowed IP (1.1.1.1) fails" \
    curl --connect-timeout 5 -sS https://1.1.1.1 -o /dev/null

# --- External-DNS bypass ---
check_blocked "external DNS (@8.8.8.8) is blocked at port 53" \
    dig @8.8.8.8 +tries=1 +timeout=2 +short example.com
check_blocked "external DNS (@1.1.1.1) is blocked at port 53" \
    dig @1.1.1.1 +tries=1 +timeout=2 +short example.com

# --- ipset population (lazy: dnsmasq adds IPs on resolve) ---
check "ipset has at least 1 entry (populated by earlier curls)" \
    bash -c "test \"\$(ipset list allowed-domains | grep -c '^[0-9]')\" -ge 1"

# --- Tools availability sanity check ---
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
