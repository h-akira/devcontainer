# tests/

Acceptance tests for the devcontainer.

There are two ways to run them:

1. **Inside the container you currently have open in VSCode** (manual,
   quick): see `firewall.sh` below. Useful for an ad-hoc check.
2. **In a brand-new throwaway container, isolated from your VSCode session**
   (automated): see `run-isolated.sh` below. Useful when you've changed
   `init-firewall.sh` / `dnsmasq.conf` / `Dockerfile` and want to verify
   it from a clean state without disturbing your active work container.

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

## run-isolated.sh

Builds a throwaway container from this repo, runs `firewall.sh` inside it,
then deletes the container, its named volumes, and the temp workspace.
Your VSCode-attached container is not touched.

```bash
./tests/run-isolated.sh
```

If tests fail you can keep the container alive to debug:

```bash
KEEP_ON_FAILURE=1 ./tests/run-isolated.sh
# or
./tests/run-isolated.sh --keep-on-failure
# the script prints `docker exec -u node -it <id> bash` for you
```

### Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| `docker` | container runtime | [Docker Desktop](https://www.docker.com/products/docker-desktop) |
| `devcontainer` | the official `@devcontainers/cli` | `npm install -g @devcontainers/cli` |
| `rsync` | copies the repo into the throwaway workspace | preinstalled on macOS / most Linux |

### What it actually does

1. Creates an empty `mktemp` workspace `/tmp/devcontainer-test-XXXXXX/`.
2. `rsync`s this repository into `<workspace>/.devcontainer/`, mirroring
   how a real consumer project would have us as a submodule. `develop/`,
   `references/`, `.git/`, and `.claude/` are excluded.
3. Runs `devcontainer up` against that workspace. Docker builds a fresh
   image and starts a container; because the workspace is in a unique
   tmp path, the `${devcontainerId}` hashes to a fresh value so the
   container's named volumes are brand new.
4. Runs `sudo /workspace/.devcontainer/tests/firewall.sh` inside.
5. On exit (success, failure, or Ctrl-C) the trap removes the container,
   removes every named volume that was attached to it, and `rm -rf`s
   the tmp workspace. With `KEEP_ON_FAILURE=1` step 5 is skipped on
   non-zero exit so you can inspect what went wrong.

## When to run

- After modifying `init-firewall.sh`, `config/dnsmasq/dnsmasq.conf`, the
  Dockerfile's network-related sections, or `devcontainer.json`'s `runArgs` /
  `mounts`. Anything that could affect the firewall or DNS path.
- Before merging a topic branch back to main.
- When investigating a "something can't reach the network" report from a user.
