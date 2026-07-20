#!/usr/bin/env bash
#
# init.sh — Agent harness bootstrap for awesm-claude-harness
#
# Brings a fresh machine (or fresh clone) to a working state for Claude Code
# agent work: checks/installs the harness TOOLING, wires up the plugin
# integrations, builds the codebase knowledge graph, then runs the project's
# own install + verification.
#
# Idempotent: every step checks before it acts — safe to re-run after a pull,
# a machine switch, or whenever you suspect drift.
# Adapted from walkinglabs/learn-harness-engineering init.sh.

set -euo pipefail

# Always operate from the repo root (the dir this script lives in).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
echo "==> Working directory: $PWD"

# ---------------------------------------------------------------------------
# Project-specific commands — EDIT THESE for your app.
# This repo has no package manifest yet, so they default to no-ops.
# Example: INSTALL_CMD=(npm install) ; VERIFY_CMD=(npm test) ; START_CMD=(npm run dev)
# ---------------------------------------------------------------------------
INSTALL_CMD=()   # dependency install (e.g. npm install / pip install -r requirements.txt)
VERIFY_CMD=()    # baseline verification (e.g. npm test / pytest)
START_CMD=()     # dev start command (e.g. npm run dev)

# helper: is a command available on PATH?
have() { command -v "$1" >/dev/null 2>&1; }

# =====================================================================
# 1. PREREQUISITES — base runtimes the harness tools depend on
# =====================================================================

# Node.js + npx — required by claude-mem (and most JS projects).
if have node; then echo "==> node $(node --version) ✓"
else echo "!! node MISSING. Install Node 20+ ('brew install node') and re-run." >&2; exit 1; fi

# pipx — isolated installer for Python CLIs. graphify is installed through it
# so its deps never collide with system Python.
if have pipx; then echo "==> pipx $(pipx --version) ✓"
else echo "==> pipx missing — installing via Homebrew"; brew install pipx && pipx ensurepath; fi

# =====================================================================
# 2. RTK (Rust Token Killer) — token-optimizing CLI proxy
# =====================================================================
# Rewrites common dev commands (git status -> rtk git status) via a Claude Code
# PreToolUse hook, cutting 60-90% of tokens on dev ops. Official Homebrew Core
# formula (github.com/Homebrew/homebrew-core) — same install pattern as vendir below.
if have rtk; then echo "==> rtk $(rtk --version | awk '{print $2}') ✓ (token proxy active via hook)"
else echo "==> rtk missing — installing via Homebrew"; brew install rtk || echo "   (rtk install failed — non-fatal, continuing without it)"; fi

# =====================================================================
# 3. graphify — codebase knowledge graph for the assistant
# =====================================================================
# Turns this repo (code + docs) into a queryable graph so the agent traverses
# structure instead of grepping raw files.
# NOTE: the PyPI package is 'graphifyy' (double y); the CLI is 'graphify'.
if have graphify; then echo "==> graphify $(graphify --version | awk '{print $2}') ✓"
else echo "==> graphify missing — installing 'graphifyy' via pipx"; pipx install graphifyy; fi

# Optional MCP/serve extra — only needed to expose the graph as an MCP server
# or share it over HTTP with a team. Uncomment to enable:
# pipx inject graphifyy "graphifyy[mcp]"

# NOTE: do NOT run `graphify claude install` here. It overwrites .claude/settings.json
# with graphify's own inline-bash PreToolUse hook, clobbering our maintained, readable
# hooks in .claude/hooks/ (graphify-grep-nudge.sh, graphify-read-nudge.sh) which the
# committed settings.json already wires up. We own the graphify hooks ourselves.
# graphify claude install   # intentionally disabled

# Build (or refresh) the knowledge graph -> graphify-out/.
# AST extraction is local; semantic edges use your configured model.
if [ -f graphify-out/graph.json ]; then
  echo "==> Updating knowledge graph (AST-only, no API cost)"
  graphify update . || echo "   (graph update failed — non-fatal)"
else
  echo "==> Building knowledge graph for the first time"
  graphify . || echo "   (graph build failed — non-fatal)"
fi

# =====================================================================
# 3b. vendir — vendored third-party skills (Carvel)
# =====================================================================
# Pulls the specific third-party skills listed in vendir.yml into
# .claude/skills/<name> (only the ones we pick, never a whole plugin) and pins
# them in vendir.lock.yml. Update later with `vendir sync`.
if have vendir; then echo "==> vendir $(vendir version 2>/dev/null | awk '/Client Version/{print $3}') ✓"
else echo "==> vendir missing — installing via Homebrew"; brew install carvel-dev/carvel/vendir || echo "   (vendir install failed — non-fatal)"; fi

if have vendir && [ -f vendir.yml ]; then
  echo "==> Syncing vendored skills (vendir sync)"
  vendir sync || echo "   (vendir sync failed — non-fatal)"
else
  echo "==> No vendir.yml (or vendir unavailable) — skipping vendored skills"
fi

# =====================================================================
# 3c. caveman — output token compression for duty/obligation work
# =====================================================================
# Compresses agent PROSE output ~65% (preserves code/paths/commands byte-for-byte).
# The harness points state-handler at it (level `full`) to keep state reports and
# progress.md token-lean. Installed as a Claude Code plugin; re-runnable.
if [ -d "$HOME/.claude/plugins/marketplaces/caveman" ]; then echo "==> caveman plugin present ✓"
else echo "==> Installing caveman"; curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash || echo "   (caveman install failed — non-fatal)"; fi

# =====================================================================
# 4. claude-mem — persistent cross-session memory
# =====================================================================
# Auto-captures session observations and re-injects relevant context into
# future sessions (data in ~/.claude-mem). Installs hooks + worker. Re-runnable.
if [ -f "$HOME/.claude-mem/claude-mem.db" ]; then echo "==> claude-mem store present ✓"
else echo "==> Installing claude-mem"; npx --yes claude-mem install || echo "   (claude-mem install failed — non-fatal)"; fi

# =====================================================================
# 5. PROJECT INSTALL + BASELINE VERIFICATION
# =====================================================================
if [ ${#INSTALL_CMD[@]} -gt 0 ]; then
  echo "==> Installing project dependencies: ${INSTALL_CMD[*]}"; "${INSTALL_CMD[@]}"
else echo "==> No INSTALL_CMD set — skipping project dependency install"; fi

if [ ${#VERIFY_CMD[@]} -gt 0 ]; then
  echo "==> Running baseline verification: ${VERIFY_CMD[*]}"; "${VERIFY_CMD[@]}"
else echo "==> No VERIFY_CMD set — skipping baseline verification"; fi

# =====================================================================
# 6. DONE — print the start command (or run it if asked)
# =====================================================================
echo "==> Harness ready."
if [ ${#START_CMD[@]} -gt 0 ]; then
  echo -n "==> Start command:"; printf ' %q' "${START_CMD[@]}"; printf '\n'
  if [ "${RUN_START_COMMAND:-0}" = "1" ]; then echo "==> Launching the app"; exec "${START_CMD[@]}"; fi
  echo "    Set RUN_START_COMMAND=1 to launch it directly."
else
  echo "==> No START_CMD set. Next: work normally, or run 'graphify query \"...\"'."
fi
