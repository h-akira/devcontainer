#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# init-firewall.sh — domain-based firewall via dnsmasq + ipset.
#
# Architecture (see develop/DNS_FILTER_PRIMER.md for the full primer):
#
#   1. dnsmasq runs on 127.0.0.1:53 with `no-resolv` and a per-domain
#      `server=/<suffix>/127.0.0.11`. Only the allowlisted suffixes have an
#      upstream, so any other query returns NXDOMAIN. On a successful resolve
#      dnsmasq pushes the IP into the `allowed-domains` ipset
#      (`ipset=/<suffix>/allowed-domains`).
#   2. /etc/resolv.conf is rewritten to `nameserver 127.0.0.1`, so apps in
#      the container go through dnsmasq.
#   3. iptables defaults to DROP. We allow:
#        - DNS (UDP/TCP 53) only to 127.0.0.1 (dnsmasq) and 127.0.0.11
#          (Docker's embedded resolver, dnsmasq's upstream).
#        - TCP to any IP currently in `allowed-domains`.
#        - The host /24 (so the IDE can reach the container).
#      Everything else is REJECTed.
#
# The combined effect is that the container can only talk to hosts whose
# domain is in dnsmasq.conf. IP-direct attempts get REJECTed (those IPs are
# never in ipset), and attempts to reach an external resolver (e.g. 8.8.8.8)
# get REJECTed at the dport-53 rule.

DNSMASQ_CONF_TEMPLATE=/opt/devcontainer/config/dnsmasq/dnsmasq.conf
DNSMASQ_CONF_RUNTIME=/tmp/dnsmasq.runtime.conf

# 0. Detect the upstream DNS from /etc/resolv.conf BEFORE we overwrite it.
#    On plain Linux + default Docker bridge this is 127.0.0.11 (Docker's
#    embedded resolver). On Docker Desktop for Mac/Windows it is typically
#    a VM-side IP like 192.168.65.7. We must use whatever is actually live
#    or dnsmasq will time out forever trying to forward queries.
UPSTREAM_DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf || true)
if [ -z "$UPSTREAM_DNS" ]; then
    echo "ERROR: could not read a nameserver from /etc/resolv.conf"
    exit 1
fi
echo "Detected upstream DNS: ${UPSTREAM_DNS}"

# 1. Save the existing Docker DNS NAT rules so we can restore them after the
#    flush. On Docker Desktop for Mac these may not exist; that's fine.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush old state.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS NAT rules.
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS NAT rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "WARN: no Docker DNS NAT rules found to restore"
fi

# 2. Create the ipset that dnsmasq will populate at resolve time.
ipset create allowed-domains hash:ip family inet timeout 0 -exist

# 3. Materialize a runtime dnsmasq config from the template by substituting
#    __UPSTREAM_DNS__ with the value detected from /etc/resolv.conf.
echo "Generating runtime dnsmasq config: ${DNSMASQ_CONF_RUNTIME}"
sed "s|__UPSTREAM_DNS__|${UPSTREAM_DNS}|g" "${DNSMASQ_CONF_TEMPLATE}" > "${DNSMASQ_CONF_RUNTIME}"

# Start dnsmasq with our allowlist config. dnsmasq is set to keep-in-foreground
# in the conf, so we daemonize via setsid+& and capture its log.
echo "Starting dnsmasq..."
pkill -x dnsmasq 2>/dev/null || true
sleep 0.2
setsid dnsmasq --conf-file="${DNSMASQ_CONF_RUNTIME}" </dev/null >/var/log/dnsmasq.log 2>&1 &
sleep 0.5
if ! pgrep -x dnsmasq >/dev/null; then
    echo "ERROR: dnsmasq failed to start. Last log lines:"
    tail -n 50 /var/log/dnsmasq.log || true
    exit 1
fi
echo "dnsmasq is running (PID $(pgrep -x dnsmasq))"

# 4. Point the container's resolver at dnsmasq. /etc/resolv.conf may be
# bind-mounted by Docker; if it's read-only we have to overwrite via
# unmount-and-rewrite, but in the default devcontainer setup it's writable.
echo "Pointing /etc/resolv.conf at 127.0.0.1 ..."
printf 'nameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf

# 5. Loopback and DNS rules.
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS (53/udp + 53/tcp) is allowed only to:
#   - 127.0.0.1: our dnsmasq (the only resolver apps see).
#   - ${UPSTREAM_DNS}: the host-side resolver dnsmasq forwards to. On plain
#     Linux this is usually 127.0.0.11 (Docker NAT magic); on Docker
#     Desktop it is a VM-side IP like 192.168.65.7.
# Inbound DNS replies are accepted by the RELATED,ESTABLISHED rule below.
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1       -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -d "$UPSTREAM_DNS" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.1       -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d "$UPSTREAM_DNS" -j ACCEPT

# SSH outbound (kept for parity with the upstream Anthropic devcontainer's
# convenience). Restrict to RELATED,ESTABLISHED for return traffic only.
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# 6. Host network — allow the IDE side to reach into the container.
HOST_IP=$(ip route | awk '/default/ {print $3; exit}')
if [ -z "$HOST_IP" ]; then
    echo "ERROR: failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
echo "Host network: ${HOST_NETWORK}"
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# 7. Default policy + main allow rules.
iptables -P INPUT  DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow TCP to any address dnsmasq has put into the ipset (i.e. an IP
# resolved from one of the allowlisted domains).
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Anything else: REJECT with admin-prohibited so apps fail fast instead of
# hanging on a SYN timeout.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 8. Verification.
echo "Firewall configuration complete"
echo

echo "Verifying firewall rules..."

# example.com is NOT in the allowlist, so DNS should NXDOMAIN and the curl
# should fail. We use --connect-timeout to avoid hanging.
if curl --connect-timeout 5 -sS https://example.com -o /dev/null 2>/dev/null; then
    echo "ERROR: was able to reach https://example.com (allowlist leak?)"
    exit 1
else
    echo "OK: https://example.com is correctly blocked"
fi

# api.github.com IS in the allowlist; it should resolve and connect.
if ! curl --connect-timeout 10 -sS https://api.github.com/zen -o /dev/null; then
    echo "ERROR: cannot reach https://api.github.com (allowlist over-restrictive?)"
    exit 1
else
    echo "OK: https://api.github.com is reachable"
fi

# sts.amazonaws.com (covered by the amazonaws.com suffix entry).
if ! curl --connect-timeout 10 -sS -o /dev/null https://sts.amazonaws.com/; then
    echo "ERROR: cannot reach https://sts.amazonaws.com"
    exit 1
else
    echo "OK: https://sts.amazonaws.com is reachable"
fi

# External-DNS bypass attempt: dig @8.8.8.8 should be REJECTed at port 53.
# We pass +tries=1 +timeout=2 so it doesn't take 30 seconds to fail.
if dig @8.8.8.8 +tries=1 +timeout=2 +short example.com >/dev/null 2>&1; then
    echo "ERROR: external DNS (@8.8.8.8) was reachable — port 53 leak"
    exit 1
else
    echo "OK: external DNS (@8.8.8.8) is correctly blocked"
fi

# Show how many entries dnsmasq has populated so far. This is just initial
# seeding from the verification curls above; the set will grow as the
# container is used.
ipset_count=$(ipset list allowed-domains | grep -c '^[0-9]' || true)
echo "ipset allowed-domains: ${ipset_count} entries (seeded by verification)"

echo "Firewall verification passed."
