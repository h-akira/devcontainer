#!/bin/bash
set -euo pipefail

# init-mcp.sh
# Copy the MCP template to /workspace/.mcp.json on first run.
# Never overwrite an existing /workspace/.mcp.json (it may contain user-edited API keys).

TEMPLATE="/opt/devcontainer/config/mcp/mcp.json.template"
TARGET="/workspace/.mcp.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "init-mcp: ERROR: ${TEMPLATE} not found in image."
  exit 1
fi

if [ -f "$TARGET" ]; then
  echo "init-mcp: ${TARGET} already exists; leaving it untouched."
  exit 0
fi

cp "$TEMPLATE" "$TARGET"
echo "init-mcp: created ${TARGET} from template."
echo "init-mcp: set CONTEXT7_API_KEY in ${TARGET} before using context7."
