#!/usr/bin/env bash
#
# install.sh — one-command project bootstrap / adoption for the awesm harness.
#
# Usage:
#   bash scripts/install.sh <project-name> [--scope project|local|user]
#     Fresh mode: creates a brand-new empty git repo named <project-name>,
#     declares the marketplace, enables the plugin, opens Claude Code (/onboard).
#
#   bash scripts/install.sh [--scope project|local|user]
#     Adopt mode (no project-name): run FROM INSIDE an existing project folder.
#     Does NOT touch your code, git history, or existing files — only merges
#     the plugin-enable block into the scope's settings file. Restart Claude
#     Code afterwards (or let this script open a fresh session for you), then
#     run /onboard — it scaffolds only what's missing, never overwrites.
#     Refuses if the folder already has its own .claude/agents, .claude/commands,
#     .claude/hooks, .claude/skills, or vendir.yml — adopting on top of those
#     would double-wire hooks and duplicate agents/commands. In that case, start
#     fresh (create a new project) or remove your own .claude/ machinery by hand,
#     then re-run.
#
#   curl -fsSL <raw-url>/scripts/install.sh | bash -s -- <project-name>
#
# --scope (default: project)
#   project  .claude/settings.json       team-shared, committed
#   local    .claude/settings.local.json this machine only, gitignored
#   user     ~/.claude/settings.json     every project on this machine — also
#            activates the harness's hooks + plugin dependencies everywhere
#
# The plugin (not this script) carries the machinery: agents, hooks, commands, skills,
# and the project scaffold templates. /onboard interviews the user, picks a work
# profile, and instantiates the scaffold. No harness clone, no branches, no history
# surgery — reset-git.sh is gone.

set -euo pipefail

MARKETPLACE_REPO="awesm-dev/awesm-claude-harness"
PLUGIN_KEY="awesm-harness@awesm"
# awesm-harness depends on these independent plugins (caveman: output
# compression, claude-mem: cross-session memory, ponytail: minimal-code
# discipline). Their marketplaces must be known BEFORE install or the
# dependency resolution fails with a cross-marketplace error — so we register
# them here instead of making the user do it by hand.
CAVEMAN_REPO="JuliusBrussee/caveman"
THEDOTMACK_REPO="thedotmack/claude-mem"
PONYTAIL_REPO="DietrichGebert/ponytail"

# --- args --------------------------------------------------------------------
PROJECT_NAME=""
SCOPE="project"
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    -h|--help)
      echo "Usage: bash scripts/install.sh [project-name] [--scope project|local|user]" >&2
      exit 0 ;;
    *)
      if [ -z "$PROJECT_NAME" ]; then PROJECT_NAME="$1"
      else echo "!! Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done
case "$SCOPE" in
  project|local|user) ;;
  *) echo "!! --scope must be one of: project, local, user (got '$SCOPE')" >&2; exit 1 ;;
esac
if [ "$SCOPE" = "user" ]; then
  echo "!! --scope user enables awesm-harness (+ its hooks + plugin dependencies:" >&2
  echo "   caveman, claude-mem, ponytail) for EVERY project you open on this machine," >&2
  echo "   not just this one. Prefer --scope project or --scope local unless you" >&2
  echo "   specifically want that." >&2
fi

# --- prerequisites -------------------------------------------------------------
command -v git >/dev/null 2>&1 || { echo "!! git is required. Install git and re-run." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "!! python3 is required. Install it and re-run." >&2; exit 1; }

# The marketplace repo is PRIVATE — plugin install uses the user's own git
# credentials. Fail early with a clear message instead of a cryptic clone error
# at plugin-install time.
if ! git ls-remote "https://github.com/${MARKETPLACE_REPO}.git" HEAD >/dev/null 2>&1; then
  echo "!! Cannot reach the awesm harness repo (github.com/${MARKETPLACE_REPO})." >&2
  echo "   Your git credentials must have read access to it. Check:" >&2
  echo "     - you are logged in (gh auth status, or an SSH key / token is set up)" >&2
  echo "     - your GitHub account has access to the awesm-dev org" >&2
  exit 1
fi

# --- resolve target settings file for the chosen scope ------------------------
# Same two keys everywhere (extraKnownMarketplaces + enabledPlugins) — scope is
# purely which file they land in.
settings_path_for_scope() {
  case "$1" in
    project) echo ".claude/settings.json" ;;
    local)   echo ".claude/settings.local.json" ;;
    user)    echo "$HOME/.claude/settings.json" ;;
  esac
}

# Idempotently merge the marketplace + enable block into $1 (a settings.json
# path) without clobbering anything already there (existing keys, permissions,
# other marketplaces are all preserved). Uses python3, not jq, so this works
# before init.sh has installed anything.
merge_settings() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  MARKETPLACE_REPO="$MARKETPLACE_REPO" CAVEMAN_REPO="$CAVEMAN_REPO" \
  THEDOTMACK_REPO="$THEDOTMACK_REPO" PONYTAIL_REPO="$PONYTAIL_REPO" \
  PLUGIN_KEY="$PLUGIN_KEY" TARGET="$target" python3 <<'PYEOF'
import json, os

target = os.environ["TARGET"]
try:
    with open(target) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

marketplaces = {
    "awesm": os.environ["MARKETPLACE_REPO"],
    "caveman": os.environ["CAVEMAN_REPO"],
    "thedotmack": os.environ["THEDOTMACK_REPO"],
    "ponytail": os.environ["PONYTAIL_REPO"],
}
known = data.setdefault("extraKnownMarketplaces", {})
for name, repo in marketplaces.items():
    known.setdefault(name, {"source": {"source": "github", "repo": repo}})

data.setdefault("enabledPlugins", {})[os.environ["PLUGIN_KEY"]] = True

with open(target, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

# --- actually install the plugin (not just declare it) -------------------------
# merge_settings only WRITES the enable block into settings.json — that declares
# the plugin but does NOT install its machinery, so /awesm-harness:onboard would
# not exist and onboarding never starts. These CLI calls do the real install at
# the chosen scope. Dependency plugins (caveman, claude-mem, ponytail) auto-
# install once their marketplaces are registered here. Idempotent: marketplace
# add is a no-op when already present; install is safe to re-run.
install_plugin_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "==> claude not on PATH — settings written, but the plugin isn't installed." >&2
    echo "    Install Claude Code, then run: claude plugin install $PLUGIN_KEY --scope $SCOPE" >&2
    return 0
  fi
  for repo in "$MARKETPLACE_REPO" "$CAVEMAN_REPO" "$THEDOTMACK_REPO" "$PONYTAIL_REPO"; do
    claude plugin marketplace add "$repo" >/dev/null 2>&1 || true
  done
  echo "==> Installing $PLUGIN_KEY (+ dependencies) at --scope $SCOPE"
  if ! claude plugin install "$PLUGIN_KEY" --scope "$SCOPE"; then
    echo "!! 'claude plugin install $PLUGIN_KEY' failed — check marketplace access." >&2
    echo "   Settings were still written; fix access and re-run the install command." >&2
    return 1
  fi
}

# --- launch Claude Code + onboarding -------------------------------------------
# Launching an interactive Claude Code session needs a real terminal AND must
# not be nested inside an existing one. Two problem cases the naive `exec
# claude` got wrong:
#   1. Already inside a Claude session (CLAUDECODE set) — pasting the curl line
#      into the Claude prompt, or running it via `!`. Spawning a nested
#      interactive claude here hangs/breaks. Print instructions instead.
#   2. `curl ... | bash` — stdin is the pipe, not a TTY, so interactive claude
#      can't attach. Reconnect it to the controlling terminal via </dev/tty.
# The command is the PLUGIN-NAMESPACED /awesm-harness:onboard — a plugin's slash
# commands register under <plugin>:<command>, so bare /onboard is an unknown
# command and onboarding silently never runs.
# $1: extra instruction line to print in the folder ("cd '<name>'" for fresh
# mode, empty for adopt mode since we're already there).
launch_claude_onboard() {
  local cd_hint="$1"
  if [ -n "${CLAUDECODE:-}" ]; then
    echo "==> Detected an active Claude Code session — not launching a nested one."
  elif ! command -v claude >/dev/null 2>&1; then
    echo "==> Claude Code isn't installed on PATH."
  elif [ -t 0 ]; then
    echo "==> Opening Claude Code…"
    exec claude "/awesm-harness:onboard"
  elif [ -e /dev/tty ]; then
    echo "==> Opening Claude Code…"
    exec claude "/awesm-harness:onboard" </dev/tty
  else
    echo "==> No terminal available to open Claude Code interactively."
  fi
  echo
  echo "==> Ready at: $(pwd)"
  echo "    To start onboarding:"
  [ -n "$cd_hint" ] && echo "      $cd_hint"
  echo "      claude                       # open a NEW Claude Code session here"
  echo "      /awesm-harness:onboard       # start onboarding"
}

if [ -n "$PROJECT_NAME" ]; then
  # ===========================================================================
  # FRESH MODE — create a brand-new empty project repo
  # ===========================================================================
  if [ -e "$PROJECT_NAME" ]; then
    echo "!! '$PROJECT_NAME' already exists here. Pick another name, or run this" >&2
    echo "   script with NO project name from inside it to adopt in place." >&2
    exit 1
  fi

  echo "==> Creating '$PROJECT_NAME' (fresh git repo)"
  mkdir -p "$PROJECT_NAME"
  cd "$PROJECT_NAME"
  git init -q

  SETTINGS_REL="$(settings_path_for_scope "$SCOPE")"
  echo "==> Enabling awesm-harness at --scope $SCOPE ($SETTINGS_REL)"
  merge_settings "$SETTINGS_REL"
  install_plugin_cli

  echo "==> '$PROJECT_NAME' is ready."
  launch_claude_onboard "cd '$PROJECT_NAME'   # (from where you ran this)"

else
  # ===========================================================================
  # ADOPT MODE — enable the harness in the CURRENT, already-populated project
  # ===========================================================================
  # Never git-init, never touch existing files or history — only the settings
  # file, and only by merging in missing keys.
  #
  # A folder with its own .claude/agents, .claude/commands, .claude/hooks,
  # .claude/skills, or vendir.yml already has conflicting machinery — could be
  # a pre-2.0 fork of THIS harness, or an unrelated hand-built Claude Code
  # setup. Either way, enabling the plugin on top would double-wire hooks and
  # duplicate agents/commands. Refuse — the harness is a start-fresh thing.
  for marker in .claude/agents .claude/commands .claude/hooks .claude/skills vendir.yml; do
    if [ -e "$marker" ]; then
      echo "!! Found '$marker' — this project already has its own .claude/agents," >&2
      echo "   .claude/commands, .claude/hooks, .claude/skills, or vendir.yml. Enabling the" >&2
      echo "   plugin on top would double-wire hooks and duplicate agents/commands." >&2
      echo "   The awesm harness is a start-fresh setup: create a NEW project with" >&2
      echo "   'bash scripts/install.sh <name>', or remove your own .claude/ machinery by" >&2
      echo "   hand first, then re-run this in-place." >&2
      exit 1
    fi
  done

  if [ -d .git ]; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "!! You have uncommitted changes here. Commit or stash them first so this" >&2
      echo "   step (and everything /onboard adds later) stays cleanly revertible." >&2
      exit 1
    fi
  else
    echo "==> Note: this folder isn't a git repo yet — there's no revert point for" >&2
    echo "    this change via git. Consider 'git init && git add -A && git commit'" >&2
    echo "    first." >&2
  fi

  SETTINGS_REL="$(settings_path_for_scope "$SCOPE")"
  echo "==> Adopting awesm-harness into $(pwd) at --scope $SCOPE ($SETTINGS_REL)"
  merge_settings "$SETTINGS_REL"
  install_plugin_cli
  echo "==> Done."

  launch_claude_onboard ""
fi
