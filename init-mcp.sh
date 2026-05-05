#!/bin/bash
set -euo pipefail

# init-mcp.sh
# Copy the MCP template to /workspace/.mcp.json on first run.
# Never overwrite an existing /workspace/.mcp.json (it may contain user-edited API keys).
# After placing the file, warn if the parent project's .gitignore does not exclude it,
# since the user is expected to write API keys (e.g. CONTEXT7_API_KEY) directly into it.

TEMPLATE="/opt/devcontainer/config/mcp/mcp.json.template"
TARGET="/workspace/.mcp.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "init-mcp: ERROR: ${TEMPLATE} not found in image."
  exit 1
fi

placed_now=0
if [ -f "$TARGET" ]; then
  echo "init-mcp: ${TARGET} already exists; leaving it untouched."
else
  cp "$TEMPLATE" "$TARGET"
  echo "init-mcp: created ${TARGET} from template."
  echo "init-mcp: set CONTEXT7_API_KEY in ${TARGET} before using context7."
  placed_now=1
fi

# .gitignore safety check: if the parent project is a git repo and .mcp.json is
# NOT ignored, warn loudly. We never modify the parent's .gitignore — that is
# the parent project's responsibility (documented in README.md).
if cd /workspace 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git check-ignore -q .mcp.json 2>/dev/null; then
    echo ""
    echo "init-mcp: ============================================================"
    echo "init-mcp: WARN: /workspace/.mcp.json is NOT covered by .gitignore."
    echo "init-mcp:       Any API key you write here may be committed to the"
    echo "init-mcp:       parent project. Add '.mcp.json' to your .gitignore"
    echo "init-mcp:       before editing the file."
    echo "init-mcp: ============================================================"
    echo ""
  fi
fi

# Exit code is intentionally 0 even with the warning — fail-close on a missing
# .gitignore line is too aggressive and would block container startup. The
# warning is meant to be loud enough to catch the user's eye.
:
