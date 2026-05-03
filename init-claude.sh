#!/bin/bash
set -euo pipefail

# init-claude.sh
# Place /home/node/.claude/settings.json from the bundled config if it does not exist.
# This applies a permissions.deny rule for ~/.aws/** so the AI does not casually
# read AWS credentials placed by the user.
#
# Note: /home/node/.claude is a Docker volume mount; the file inside the volume
# survives container rebuilds. We never overwrite a user-edited settings.json.

CLAUDE_DIR="/home/node/.claude"
TARGET="${CLAUDE_DIR}/settings.json"
SOURCE="/opt/devcontainer/config/claude/settings.json"

mkdir -p "$CLAUDE_DIR"

if [ -f "$TARGET" ]; then
  echo "init-claude: ${TARGET} already exists; leaving it untouched."
  exit 0
fi

if [ ! -f "$SOURCE" ]; then
  echo "init-claude: ERROR: ${SOURCE} not found in image."
  exit 1
fi

cp "$SOURCE" "$TARGET"
echo "init-claude: installed ${TARGET} from bundled template."
