#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/magic_mode.yaml}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Config not found: $CONFIG_FILE"
  echo "Usage: magic_mode.sh [config.yaml]"
  exit 1
fi

# Parse config with python (available on macOS).
eval "$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)
print(f'LOOKBACK_HOURS={cfg.get(\"lookback_hours\", 24)}')
repos = cfg.get('repos', [])
# Output repos as a bash array assignment.
escaped = ' '.join(f'\"{r}\"' for r in repos)
print(f'REPOS=({escaped})')
")"

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "❌ No repos configured in $CONFIG_FILE"
  exit 1
fi

echo "Magic Mode: scanning ${#REPOS[@]} repo(s), lookback=${LOOKBACK_HOURS}h"

for REPO in "${REPOS[@]}"; do
  if [[ ! -d "$REPO" ]]; then
    echo "⚠️  Skipping (not found): $REPO"
    continue
  fi

  # Find all files containing a MAGIC DOC header.
  MAGIC_FILES=$(grep -rl "^# MAGIC DOC:" "$REPO" --include="*.md" 2>/dev/null || true)

  if [[ -z "$MAGIC_FILES" ]]; then
    echo "  No MAGIC DOC files in $REPO"
    continue
  fi

  FILE_COUNT=$(echo "$MAGIC_FILES" | wc -l | tr -d ' ')
  echo "  Found $FILE_COUNT MAGIC DOC file(s) in $REPO"

  # Build the list of files for the prompt.
  FILE_LIST=""
  for f in $MAGIC_FILES; do
    REL=$(python3 -c "import os; print(os.path.relpath('$f', '$REPO'))")
    FILE_LIST="${FILE_LIST}  - ${REL}\n"
  done

  PROMPT=$(cat <<PROMPT_EOF
You are updating MAGIC DOC files in this repository. A MAGIC DOC is a markdown file whose first line starts with "# MAGIC DOC:". These are self-updating internal docs.

Your job:
1. Read the git log for the last ${LOOKBACK_HOURS} hours to understand recent changes.
2. Read the current state of the codebase (directory structure, key files).
3. For each MAGIC DOC file listed below, read it, then update it IN PLACE so the content reflects the current state of the project and any recent changes.

MAGIC DOC files to update:
$(echo -e "$FILE_LIST")

Rules for updating MAGIC DOC content:
- Keep the "# MAGIC DOC: <title>" header line intact.
- If there is an italicized instruction line right after the header (e.g. *Keep this doc focused on...*), follow that instruction.
- Content should be: terse, architecture-focused, current, high-signal.
- NOT a changelog. NOT line-by-line code docs. Focus on overviews, entry points, design decisions, and non-obvious patterns.
- Remove stale information. Add new information from recent changes.
- Do not add information you are not confident about.
- Only edit the MAGIC DOC files listed above. Do not create new files or modify any other files.

Start by running: git log --oneline --since="${LOOKBACK_HOURS} hours ago"
Then explore the repo structure and update each MAGIC DOC file.
PROMPT_EOF
)

  echo "  Running Claude Code on $REPO..."
  claude --dangerously-skip-permissions \
    -p "$PROMPT" \
    --cwd "$REPO" \
    --model sonnet \
    --max-turns 20 \
    --output-format text \
    2>&1 | tail -5

  echo "  Done: $REPO"
done

echo "Magic Mode complete."
