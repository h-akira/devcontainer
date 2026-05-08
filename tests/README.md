# tests/

Acceptance tests for the devcontainer. Run them inside a *running* container —
they assume `init-firewall.sh` has already populated dnsmasq / iptables / ipset.

## firewall.sh

End-to-end check of the DNS-filter firewall plus a sanity check that the
toolchain we shipped is installed.

```bash
sudo /workspace/.devcontainer/tests/firewall.sh
# Password: devcontainer
```

What it covers:

| Group | Examples |
|-------|----------|
| Process & config state | dnsmasq is running; ipset exists; resolv.conf points at 127.0.0.1 |
| Allowed domains | github / aws / pypi / npm / debian reach |
| Blocked domains | example.com / reddit.com / wikipedia.org return NXDOMAIN |
| IP-direct attack | curl https://1.1.1.1 is REJECTed |
| External-DNS bypass | dig @8.8.8.8 / @1.1.1.1 are REJECTed at port 53 |
| ipset population | dnsmasq has actually added entries on resolve |
| Toolchain | aws / uv / node / nvim / vim symlink / deno / tmux |

The script keeps going on failure and prints a summary at the end. Exit code
is 0 if all checks pass, 1 if any failed.

## When to run

- After modifying `init-firewall.sh`, `config/dnsmasq/dnsmasq.conf`, the
  Dockerfile's network-related sections, or `devcontainer.json`'s `runArgs` /
  `mounts`. Anything that could affect the firewall or DNS path.
- Before merging a topic branch back to main.
- When investigating a "something can't reach the network" report from a user.
