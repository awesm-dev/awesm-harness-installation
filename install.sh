#!/usr/bin/env bash
#
# awesm-harness-install.sh — one-command project bootstrap from the awesm harness.
#
# Usage:   bash scripts/awesm-harness-install.sh <project-name>
# Example: bash scripts/awesm-harness-install.sh project1
#
# What it does, so a non-technical teammate never has to:
#   1. Clones the awesm harness into a new folder named <project-name>
#   2. Renames the harness to the project name
#   3. Runs init.sh (installs tooling, builds the knowledge graph)
#   4. Opens Claude Code in the new folder and starts onboarding (/onboard)
#
# NOTE: the harness git history is intentionally KEPT here. /onboard checks out
# the project-type branch during the interview, then runs scripts/reset-git.sh to
# drop the harness history and start the project's own repo — only once we know
# which variant the project is.

set -euo pipefail

REPO_URL="https://github.com/awesm-dev/awesm-claude-harness.git"
HARNESS_SLUG="awesm-claude-harness"

# --- input -----------------------------------------------------------------
PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "Usage: bash scripts/awesm-harness-install.sh <project-name>" >&2
  echo "Example: bash scripts/awesm-harness-install.sh project1" >&2
  exit 1
fi
if [ -e "$PROJECT_NAME" ]; then
  echo "!! '$PROJECT_NAME' already exists here. Pick another name or remove it first." >&2
  exit 1
fi

# --- prerequisites ---------------------------------------------------------
command -v git >/dev/null 2>&1 || { echo "!! git is required. Install git and re-run." >&2; exit 1; }

# portable in-place sed (GNU vs BSD/macOS)
sed_inplace() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

# --- 1. clone --------------------------------------------------------------
# --no-single-branch so all project-type branch tips come down with the clone;
# /onboard needs them to `git checkout` the right variant. Still shallow (depth 1)
# because the harness history is discarded by reset-git.sh at the end of onboarding.
echo "==> Creating '$PROJECT_NAME' from the awesm harness"
git clone --depth 1 --no-single-branch "$REPO_URL" "$PROJECT_NAME"

# the bootstrap script is a tool, not part of the new project — drop its copy
rm -f "$PROJECT_NAME/scripts/awesm-harness-install.sh"

# the README documents the harness itself — blank it so the new project starts fresh
: > "$PROJECT_NAME/README.md"

# --- 2. rename harness -> project name (markdown docs only, safe) ----------
echo "==> Renaming harness references to '$PROJECT_NAME'"
while IFS= read -r -d '' f; do
  sed_inplace "s/${HARNESS_SLUG}/${PROJECT_NAME}/g" "$f"
done < <(find "$PROJECT_NAME" -type f -name '*.md' -not -path '*/.git/*' -print0)

# --- 3. install tooling ----------------------------------------------------
echo "==> Installing tooling (init.sh)"
( cd "$PROJECT_NAME" && bash init.sh ) || echo "   (init.sh reported issues — continuing; the agent can finish setup)"

# --- 4. open Claude Code and start onboarding ------------------------------
cd "$PROJECT_NAME"
echo "==> '$PROJECT_NAME' is ready. Opening Claude Code…"
if command -v claude >/dev/null 2>&1; then
  exec claude "/onboard"
else
  echo
  echo "Claude Code isn't installed on PATH. To finish:"
  echo "  1. Open this folder in Claude Code:  $(pwd)"
  echo "  2. Type:  /onboard"
fi
