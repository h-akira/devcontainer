#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
gh_count=0
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
    gh_count=$((gh_count + 1))
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
if [ "$gh_count" -eq 0 ]; then
    echo "ERROR: 0 GitHub CIDR ranges added (aggregate may have produced empty output silently)"
    exit 1
fi
echo "Added $gh_count GitHub CIDR ranges"

# Fetch AWS IP ranges (covers all AWS services and SSO endpoints)
echo "Fetching AWS IP ranges..."
aws_ranges=$(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json)
if [ -z "$aws_ranges" ]; then
    echo "ERROR: Failed to fetch AWS IP ranges"
    exit 1
fi

if ! echo "$aws_ranges" | jq -e '.prefixes' >/dev/null; then
    echo "ERROR: AWS IP ranges response missing 'prefixes' field"
    exit 1
fi

echo "Processing AWS IPv4 ranges..."
aws_count=0
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "WARN: Skipping invalid CIDR from AWS ip-ranges: $cidr"
        continue
    fi
    ipset add allowed-domains "$cidr" 2>/dev/null || true
    aws_count=$((aws_count + 1))
done < <(echo "$aws_ranges" | jq -r '.prefixes[].ip_prefix' | aggregate -q)
if [ "$aws_count" -eq 0 ]; then
    echo "ERROR: 0 AWS CIDR ranges added (aggregate may have produced empty output silently)"
    exit 1
fi
echo "Added $aws_count AWS CIDR ranges"

# IPv6 is disabled at the kernel level via runArgs sysctls (see devcontainer.json),
# so we do not need to populate AWS IPv6 ranges into ipset. If you re-enable IPv6
# in the future, also bring up ip6tables with a fail-close policy and uncomment
# the block below to allow AWS IPv6 traffic.
#
# ipset create allowed-domains-v6 hash:net family inet6 2>/dev/null || true
# aws_v6_count=0
# while read -r cidr; do
#     if [[ ! "$cidr" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
#         echo "WARN: Skipping invalid IPv6 CIDR from AWS ip-ranges: $cidr"
#         continue
#     fi
#     ipset add allowed-domains-v6 "$cidr" 2>/dev/null || true
#     aws_v6_count=$((aws_v6_count + 1))
# done < <(echo "$aws_ranges" | jq -r '.ipv6_prefixes[].ipv6_prefix' | aggregate -q)
# echo "Added $aws_v6_count AWS IPv6 CIDR ranges"

# Resolve and add other allowed domains.
#
# IMPORTANT — `deb.debian.org` and `security.debian.org` are allowed only to
# support the password-sudo `apt install` workflow used in the submodule mode
# (see Dockerfile and README.md "sudo の運用"). When this repo is vendored in
# (after `git submodule deinit`) and the password-sudo block in Dockerfile is
# commented out, REMOVE these two domains here as well so the allowlist stays
# minimal.
#
# We split domains into two groups:
#
#   1) "single-resolve" — stable hosts where one dig is enough. Either the DNS
#      returns multiple IPs in one answer (e.g. registry.npmjs.org returns ~12),
#      the host has a single stable IP (e.g. api.anthropic.com), the domain
#      backs onto AWS (covered by ip-ranges.json above), or it is rarely hit so
#      a stale IP is unlikely to cause noticeable failures.
#
#   2) "multi-resolve" — Fastly-fronted CDNs that return only one IP per query
#      AND are hit frequently (apt, pip/uvx). Without multiple resolves, the IP
#      resolved at runtime can land outside the snapshot we took at startup,
#      which is exactly what bit `sudo apt install` early on. We dig each of
#      these 5 times to capture the rotating subset.

resolve_and_allow() {
    local domain="$1"
    local attempts="$2"
    echo "Resolving $domain (${attempts} attempt(s))..."
    local ips
    ips=$(for _ in $(seq 1 "$attempts"); do
              dig +noall +answer A "$domain"
              [ "$attempts" -gt 1 ] && sleep 0.1
          done | awk '$4 == "A" {print $5}' | sort -u)
    if [ -z "$ips" ]; then
        echo "WARN: Failed to resolve $domain (skipping)"
        return 0
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
}

# Group 1: single-resolve
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "context7.com" \
    "mcp.context7.com" \
    "raw.githubusercontent.com" \
    "codeload.github.com" \
    "objects.githubusercontent.com" \
    "astral.sh"; do
    resolve_and_allow "$domain" 1
done

# Group 2: multi-resolve (Fastly CDN, hit by apt / pip)
for domain in \
    "deb.debian.org" \
    "security.debian.org" \
    "pypi.org" \
    "files.pythonhosted.org"; do
    resolve_and_allow "$domain" 5
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"

# Report ipset population so we can monitor pressure on the default maxelem (65536).
# This is informational only — when the count approaches the limit, raise maxelem
# explicitly via "ipset create allowed-domains hash:net maxelem N".
ipset_count=$(ipset list allowed-domains | grep -c '^[0-9]')
echo "ipset allowed-domains: $ipset_count entries (default maxelem is 65536)"

echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Verify AWS endpoint reachability via sts.amazonaws.com.
# We use STS because it's the core AWS endpoint that aws CLI / SDKs always hit,
# and is covered by the AWS IP ranges we just installed. We only check that
# TCP/TLS handshake succeeds (any HTTP status counts as reachable — typically
# 302 redirect with empty body, ~0 bytes). No -L (redirect-follow) and no -f
# (fail on 4xx) to keep the assertion minimal: "AWS routing is open".
if ! curl --connect-timeout 5 -sS -o /dev/null https://sts.amazonaws.com/; then
    echo "ERROR: Firewall verification failed - unable to reach https://sts.amazonaws.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://sts.amazonaws.com as expected"
fi
