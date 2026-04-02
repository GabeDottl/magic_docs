#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/magic_docs.yaml"
MAGIC_SCRIPT="$SCRIPT_DIR/magic_docs.sh"

# Colors.
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

header() {
  echo ""
  echo -e "${BOLD}${CYAN}  ✦ Magic Docs Setup${RESET}"
  echo -e "${DIM}  Self-updating docs for your codebase${RESET}"
  echo ""
}

divider() {
  echo -e "${DIM}  ─────────────────────────────────────${RESET}"
}

# Check prereqs.
check_prereqs() {
  local missing=0
  if ! command -v claude &>/dev/null; then
    echo -e "  ${RED}✗${RESET} Claude Code CLI not found"
    echo -e "    Install: ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    missing=1
  else
    echo -e "  ${GREEN}✓${RESET} Claude Code CLI"
  fi

  if ! command -v python3 &>/dev/null; then
    echo -e "  ${RED}✗${RESET} Python 3 not found"
    missing=1
  else
    echo -e "  ${GREEN}✓${RESET} Python 3"
  fi

  if ! python3 -c "import yaml" &>/dev/null; then
    echo -e "  ${RED}✗${RESET} PyYAML not installed"
    echo -e "    Install: ${DIM}pip3 install pyyaml${RESET}"
    missing=1
  else
    echo -e "  ${GREEN}✓${RESET} PyYAML"
  fi

  if [[ $missing -eq 1 ]]; then
    echo ""
    echo -e "  ${RED}Fix the above before continuing.${RESET}"
    exit 1
  fi
  echo ""
}

# Collect repos interactively.
collect_repos() {
  REPOS=()
  echo -e "${BOLD}  1. Add repositories${RESET}"
  echo -e "  ${DIM}Enter absolute paths to git repos containing MAGIC DOC files.${RESET}"
  echo -e "  ${DIM}Press Enter on an empty line when done.${RESET}"
  echo ""

  while true; do
    echo -ne "  ${CYAN}repo path${RESET} (or Enter to finish): "
    read -r repo_path

    # Empty = done.
    if [[ -z "$repo_path" ]]; then
      if [[ ${#REPOS[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}You need at least one repo.${RESET}"
        continue
      fi
      break
    fi

    # Expand ~ manually.
    repo_path="${repo_path/#\~/$HOME}"

    # Validate.
    if [[ ! -d "$repo_path" ]]; then
      echo -e "  ${RED}✗ Directory not found:${RESET} $repo_path"
      continue
    fi

    if [[ ! -d "$repo_path/.git" ]]; then
      echo -e "  ${YELLOW}⚠ Not a git repo${RESET} (no .git dir). Add anyway? [y/N] "
      read -r yn
      if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
        continue
      fi
    fi

    echo -e "  ${GREEN}✓ Added${RESET}"

    REPOS+=("$repo_path")
  done

  echo ""
  echo -e "  ${DIM}${#REPOS[@]} repo(s) configured.${RESET}"
}

# Ask for lookback hours.
collect_lookback() {
  echo ""
  divider
  echo ""
  echo -e "${BOLD}  2. Lookback window${RESET}"
  echo -e "  ${DIM}How many hours of git history should Claude consider?${RESET}"
  echo ""
  echo -ne "  ${CYAN}hours${RESET} [24]: "
  read -r hours
  LOOKBACK_HOURS="${hours:-24}"

  # Validate it's a number.
  if ! [[ "$LOOKBACK_HOURS" =~ ^[0-9]+$ ]]; then
    echo -e "  ${YELLOW}Not a number, using 24.${RESET}"
    LOOKBACK_HOURS=24
  fi

  echo -e "  ${GREEN}✓${RESET} Lookback: ${LOOKBACK_HOURS}h"
}

# Ask about scheduling.
collect_schedule() {
  echo ""
  divider
  echo ""
  echo -e "${BOLD}  3. Schedule${RESET}"
  echo -e "  ${DIM}How often should Magic Docs run?${RESET}"
  echo ""
  echo -e "  ${BOLD}1${RESET})  Every 6 hours"
  echo -e "  ${BOLD}2${RESET})  Every 12 hours"
  echo -e "  ${BOLD}3${RESET})  Once daily (midnight)"
  echo -e "  ${BOLD}4${RESET})  Once daily (pick an hour)"
  echo -e "  ${BOLD}5${RESET})  Custom cron expression"
  echo -e "  ${BOLD}6${RESET})  Skip — I'll run it manually"
  echo ""
  echo -ne "  ${CYAN}choice${RESET} [3]: "
  read -r choice
  choice="${choice:-3}"

  CRON_EXPR=""
  SKIP_CRON=0

  case "$choice" in
    1)
      CRON_EXPR="0 */6 * * *"
      echo -e "  ${GREEN}✓${RESET} Every 6 hours"
      ;;
    2)
      CRON_EXPR="0 */12 * * *"
      echo -e "  ${GREEN}✓${RESET} Every 12 hours"
      ;;
    3)
      CRON_EXPR="0 0 * * *"
      echo -e "  ${GREEN}✓${RESET} Daily at midnight"
      ;;
    4)
      echo -ne "  ${CYAN}hour${RESET} (0-23) [8]: "
      read -r hour
      hour="${hour:-8}"
      if ! [[ "$hour" =~ ^[0-9]+$ ]] || [[ "$hour" -gt 23 ]]; then
        echo -e "  ${YELLOW}Invalid, using 8.${RESET}"
        hour=8
      fi
      CRON_EXPR="0 $hour * * *"
      echo -e "  ${GREEN}✓${RESET} Daily at ${hour}:00"
      ;;
    5)
      echo -ne "  ${CYAN}cron expression${RESET}: "
      read -r CRON_EXPR
      if [[ -z "$CRON_EXPR" ]]; then
        echo -e "  ${YELLOW}Empty expression, skipping cron.${RESET}"
        SKIP_CRON=1
      else
        echo -e "  ${GREEN}✓${RESET} Custom: $CRON_EXPR"
      fi
      ;;
    6)
      SKIP_CRON=1
      echo -e "  ${GREEN}✓${RESET} Manual mode — run with: ${DIM}./magic_docs.sh${RESET}"
      ;;
    *)
      CRON_EXPR="0 0 * * *"
      echo -e "  ${YELLOW}Unknown choice, defaulting to daily at midnight.${RESET}"
      ;;
  esac
}

# Write config.
write_config() {
  echo ""
  divider
  echo ""
  echo -e "${BOLD}  Writing config...${RESET}"

  local yaml="# magic_mode configuration\n"
  yaml+="# Generated by setup.sh\n\n"
  yaml+="lookback_hours: ${LOOKBACK_HOURS}\n\n"
  yaml+="repos:\n"
  for repo in "${REPOS[@]}"; do
    yaml+="  - ${repo}\n"
  done

  echo -e "$yaml" > "$CONFIG_FILE"
  echo -e "  ${GREEN}✓${RESET} Wrote $CONFIG_FILE"
}

# Install cron job.
install_cron() {
  if [[ $SKIP_CRON -eq 1 ]]; then
    return
  fi

  echo ""
  LOG_FILE="$SCRIPT_DIR/magic_docs.log"
  CRON_LINE="$CRON_EXPR $MAGIC_SCRIPT $CONFIG_FILE >> $LOG_FILE 2>&1"

  echo -e "  ${DIM}Cron entry:${RESET}"
  echo -e "  ${DIM}$CRON_LINE${RESET}"
  echo ""
  echo -ne "  Install this cron job? [Y/n] "
  read -r confirm
  confirm="${confirm:-Y}"

  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    # Remove any existing magic_mode cron entries, then add new one.
    (crontab -l 2>/dev/null | grep -v "magic_docs.sh" || true; echo "$CRON_LINE") | crontab -
    echo -e "  ${GREEN}✓${RESET} Cron job installed"
    echo -e "  ${DIM}Logs: $LOG_FILE${RESET}"
  else
    echo -e "  ${DIM}Skipped. Add manually:${RESET}"
    echo -e "  ${DIM}$CRON_LINE${RESET}"
  fi
}

# Summary.
summary() {
  echo ""
  divider
  echo ""
  echo -e "${BOLD}${GREEN}  ✦ Setup complete!${RESET}"
  echo ""
  echo -e "  ${BOLD}Repos:${RESET}"
  for repo in "${REPOS[@]}"; do
    echo -e "    ${repo}"
  done
  echo -e "  ${BOLD}Lookback:${RESET} ${LOOKBACK_HOURS}h"
  if [[ $SKIP_CRON -eq 0 ]]; then
    echo -e "  ${BOLD}Schedule:${RESET} $CRON_EXPR"
  else
    echo -e "  ${BOLD}Schedule:${RESET} manual"
  fi
  echo ""
  echo -e "  Run now:  ${DIM}./magic_docs.sh${RESET}"
  echo -e "  Reconfig: ${DIM}./setup.sh${RESET}"
  echo ""
}

# Main.
header
check_prereqs
collect_repos
collect_lookback
collect_schedule
write_config
install_cron
summary
