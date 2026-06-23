#!/usr/bin/env bash
#
# update.sh — pull the latest awesm harness into THIS existing project.
#
# Usage:   bash update.sh [branch-or-tag]
# Example: bash update.sh           # latest on main
#          bash update.sh v1.2.0    # a specific release tag
#
# What it does:
#   1. Fetches the latest harness from GitHub
#   2. Overwrites only harness-OWNED files (skills, agents, commands, hooks,
#      rules, settings.json, init.sh, rubric, checklist) — backed up first
#   3. Leaves YOUR project content untouched (see "NEVER touched" below)
#   4. Stamps .harness-version and re-runs init.sh to verify
#
# Harness-owned (overwritten):  .claude/skills .claude/agents .claude/commands
#   .claude/hooks .claude/rules .claude/settings.json init.sh
#   evaluator-rubric.md clean-state-checklist.md .graphifyignore update.sh
#
# NEVER touched (your project): AGENTS.md progress.md README.md .mcp.json
#   .claude/settings.local.json docs/ src/ scripts/ .git/ graphify-out/

set -euo pipefail

REPO_URL="https://github.com/awesm-dev/awesm-claude-harness.git"
REF="${1:-main}"

HARNESS_DIRS=( ".claude/skills" ".claude/agents" ".claude/commands" ".claude/hooks" ".claude/rules" )
HARNESS_FILES=( ".claude/settings.json" "init.sh" "evaluator-rubric.md" "clean-state-checklist.md" ".graphifyignore" )

# --- preconditions ---------------------------------------------------------
[ -d .claude ] || { echo "!! Run this from your project root (no .claude/ here)." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "!! git is required. Install git and re-run." >&2; exit 1; }

# --- fetch latest harness --------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching latest harness ($REF)"
git clone --depth 1 --branch "$REF" "$REPO_URL" "$TMP/harness" 2>/dev/null \
  || git clone --depth 1 "$REPO_URL" "$TMP/harness"

NEW_VER="$(git -C "$TMP/harness" rev-parse --short HEAD)"
CUR_VER="$(cat .harness-version 2>/dev/null || echo 'unknown')"

if [ "$NEW_VER" = "$CUR_VER" ]; then
  echo "==> Already up to date ($CUR_VER). Nothing to do."
  exit 0
fi

# --- back up what we're about to overwrite ---------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=".harness-backup-$STAMP"
echo "==> Backing up current harness files to $BACKUP/"
for p in "${HARNESS_DIRS[@]}" "${HARNESS_FILES[@]}" "update.sh"; do
  if [ -e "$p" ]; then
    mkdir -p "$BACKUP/$(dirname "$p")"
    cp -R "$p" "$BACKUP/$p"
  fi
done

# --- overwrite harness-owned paths -----------------------------------------
echo "==> Updating harness files ($CUR_VER -> $NEW_VER)"
for d in "${HARNESS_DIRS[@]}"; do
  if [ -e "$TMP/harness/$d" ]; then
    rm -rf "$d"
    mkdir -p "$(dirname "$d")"
    cp -R "$TMP/harness/$d" "$d"
  fi
done
for f in "${HARNESS_FILES[@]}"; do
  if [ -e "$TMP/harness/$f" ]; then
    mkdir -p "$(dirname "$f")"
    cp "$TMP/harness/$f" "$f"
  fi
done

# AGENTS.md holds YOUR project context — don't clobber it. If the upstream
# template changed, drop it beside yours for a manual merge.
if [ -e "$TMP/harness/AGENTS.md" ] && ! diff -q "$TMP/harness/AGENTS.md" AGENTS.md >/dev/null 2>&1; then
  cp "$TMP/harness/AGENTS.md" AGENTS.md.new
  echo "   AGENTS.md changed upstream — saved as AGENTS.md.new (merge manually, then delete it)"
fi

echo "$NEW_VER" > .harness-version

# --- verify ----------------------------------------------------------------
echo "==> Re-verifying (init.sh)"
bash init.sh || echo "   (init.sh reported issues — review the output above)"

echo "==> Done. Harness updated to $NEW_VER. Backup kept in $BACKUP/"

# --- self-update (LAST: replaces this running script in place) -------------
if [ -e "$TMP/harness/update.sh" ]; then
  cp "$TMP/harness/update.sh" update.sh
fi
