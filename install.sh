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

# helper: is a command available on PATH?
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Package manager. This script ran only on macOS for its first months: every
# install was `brew`, so on Fedora and Ubuntu it installed nothing, printed
# nothing alarming, and exited 0 — a clean run that had done no work. Every
# install below goes through pkg_install so the failure is at least loud.
# ---------------------------------------------------------------------------
if   have brew;    then PKG=brew
elif have dnf;     then PKG=dnf
elif have apt-get; then PKG=apt
elif have yum;     then PKG=yum
elif have apk;     then PKG=apk
else                    PKG=none; fi
echo "==> package manager: $PKG"

# sudo only when there is a human to answer the prompt. Run from Claude Code or a
# pipe, a sudo prompt hangs or fails; print the command instead so the person runs it.
INTERACTIVE=0; [ -t 0 ] && [ -z "${CLAUDECODE:-}" ] && INTERACTIVE=1
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

# pkg_install <brew-name> <dnf-name> <apt-name> <apk-name>
# Any name may be "-" to mean "not available via that manager".
pkg_install() {
  local brew_n="$1" dnf_n="$2" apt_n="$3" apk_n="$4" cmd=""
  case "$PKG" in
    brew) [ "$brew_n" != "-" ] && cmd="brew install $brew_n" ;;
    dnf)  [ "$dnf_n"  != "-" ] && cmd="$SUDO dnf install -y $dnf_n" ;;
    yum)  [ "$dnf_n"  != "-" ] && cmd="$SUDO yum install -y $dnf_n" ;;
    apt)  [ "$apt_n"  != "-" ] && cmd="$SUDO apt-get install -y $apt_n" ;;
    apk)  [ "$apk_n"  != "-" ] && cmd="$SUDO apk add $apk_n" ;;
  esac
  if [ -z "$cmd" ]; then
    echo "!! no install path for '$brew_n' with $PKG — install it by hand and re-run." >&2
    return 1
  fi
  if [ -n "$SUDO" ] && [ "$INTERACTIVE" -eq 0 ] && [ "$PKG" != "brew" ]; then
    echo "!! needs sudo, and there is no terminal to type the password into." >&2
    echo "   Run this yourself, then re-run init.sh:" >&2
    echo "     $cmd" >&2
    return 1
  fi
  echo "==> $cmd"; $cmd
}


MARKETPLACE_REPO="awesm-dev/awesm-claude-harness"
# Two harnesses live in this marketplace. --agent picks the agent-builder one.
#   awesm-harness        co-pilot work (web app / automation / marketing) + deploy
#   awesm-agent  builds a Hermes agent profile; no deploy path
PLUGIN_NAME="awesm-harness"
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
    --agent|--agent-harness) PLUGIN_NAME="awesm-agent"; shift ;;
    -h|--help)
      echo "Usage: bash scripts/install.sh [project-name] [--agent] [--scope project|local|user]" >&2
      echo "  --agent   install awesm-agent (build a Hermes agent) instead of" >&2
      echo "            awesm-harness (co-pilot work: web app / automation / marketing)" >&2
      exit 0 ;;
    *)
      if [ -z "$PROJECT_NAME" ]; then PROJECT_NAME="$1"
      else echo "!! Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done
PLUGIN_KEY="$PLUGIN_NAME@awesm"
case "$PROJECT_NAME" in
  *.sh|*/*|-*)
    echo "!! '$PROJECT_NAME' doesn't look like a project name (looks like a file/path/flag)." >&2
    echo "   Usage: bash scripts/install.sh [project-name] [--scope project|local|user]" >&2
    echo "   Example: bash scripts/install.sh my-project" >&2
    exit 1 ;;
esac
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

# --- ensure GitHub access (gh installed + logged in + git over HTTPS) ----------
# The harness repo is PRIVATE, so cloning it needs a GitHub login; the dependency
# repos are public but get cloned via ssh-style URLs, which need a key unless git
# is pointed at HTTPS. Make all of that automatic: install gh, log in (browser),
# wire git to gh's HTTPS credentials. Needs a real terminal — run by pasting into
# your terminal (e.g. `bash <(curl -fsSL <url>)`), NOT a bare `curl | bash` pipe,
# which has no terminal for the browser login to attach to.
ensure_github_access() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "==> GitHub CLI (gh) not found — installing…"
    if command -v brew >/dev/null 2>&1; then brew install gh
    elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y gh
    else echo "!! Install GitHub CLI (https://cli.github.com), then re-run." >&2; exit 1; fi
  fi
  if ! gh auth status >/dev/null 2>&1; then
    if [ -t 0 ]; then
      echo "==> Logging in to GitHub (a browser will open — authorize once)…"
      gh auth login --hostname github.com --git-protocol https --web \
        || { echo "!! GitHub login didn't finish. Run 'gh auth login' then re-run." >&2; exit 1; }
    else
      echo "!! Not logged in to GitHub, and no terminal to open the login." >&2
      echo "   Run 'gh auth login' in your terminal, then re-run this installer" >&2
      echo "   (or paste it as: bash <(curl -fsSL <installer-url>) <name>)." >&2
      exit 1
    fi
  fi
  # git uses gh's HTTPS credentials; rewrite ssh-style GitHub URLs to HTTPS so
  # dependency clones don't fall back to SSH (which needs a key).
  gh auth setup-git >/dev/null 2>&1 || true
  git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
}
ensure_github_access

# The marketplace repo is PRIVATE — plugin install uses the user's own git
# credentials. Fail early with a clear message instead of a cryptic clone error
# at plugin-install time.
# GIT_TERMINAL_PROMPT=0 so an un-authed machine fails fast here instead of
# hanging on an invisible username/password prompt (stderr is silenced below).
if ! GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/${MARKETPLACE_REPO}.git" HEAD >/dev/null 2>&1; then
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

# Only the awesm marketplace — it hosts the harness AND its 3 dependency plugins
# (caveman, claude-mem, ponytail), so registering it covers all four.
known = data.setdefault("extraKnownMarketplaces", {})
known.setdefault("awesm", {"source": {"source": "github", "repo": os.environ["MARKETPLACE_REPO"]}})

# Enable the harness AND its three dependency plugins, explicitly.
#
# Do not rely on `claude plugin install` to enable the dependencies: it only
# enables the ones it actually INSTALLS, so the moment a dependency is already
# present on the machine it is skipped and never enabled in THIS project. The
# parent plugin then reports "failed to load — Dependency X is not installed"
# (Claude Code says "not installed" for a dependency that is merely disabled
# here), and a plugin that fails to load has NO slash commands — which is how
# `/<plugin>:onboard` became an unknown command straight after a green install.
# Writing all four deterministically makes the outcome independent of what this
# machine happened to have already.
enabled = data.setdefault("enabledPlugins", {})
enabled[os.environ["PLUGIN_KEY"]] = True
for dep in ("caveman@awesm", "claude-mem@awesm", "ponytail@awesm"):
    enabled.setdefault(dep, True)

# Pre-approve project .mcp.json MCP servers (the plugin ships github + notion) so
# the auto-opened Claude Code session doesn't stop on the first-run MCP trust
# prompt — which a piped `curl | bash` launch can't cleanly answer.
data["enableAllProjectMcpServers"] = True

with open(target, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

# --- actually install the plugin (not just declare it) -------------------------
# merge_settings only WRITES the enable block into settings.json — that declares
# the plugin but does NOT install its machinery, so /$PLUGIN_NAME:onboard would
# not exist and onboarding never starts. These CLI calls do the real install at
# the chosen scope. Dependency plugins (caveman, claude-mem, ponytail) auto-
# install once their marketplaces are registered here. Idempotent: marketplace
# add is a no-op when already present; install is safe to re-run.
# Is the plugin installed and enabled FOR THIS PROJECT?
#
# `claude plugin list` is MACHINE-WIDE: it lists every project's installs, so
# parsing it answers "is this plugin enabled somewhere", not "here". Two projects
# on different versions both show up, which looks like duplicates and can green-light
# a project where the plugin is not enabled at all. The authoritative record is
# ~/.claude/plugins/installed_plugins.json, keyed by projectPath — filter on $PWD.
# Enablement itself lives in the project's own settings file.
plugin_installed_version() {
  PLUGIN_KEY="$PLUGIN_KEY" HERE="$PWD" python3 - <<'PYEOF' 2>/dev/null
import json, os
try:
    d = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
except Exception:
    raise SystemExit(0)
here = os.path.realpath(os.environ["HERE"])
for e in d.get("plugins", {}).get(os.environ["PLUGIN_KEY"], []):
    p = e.get("projectPath")
    if p and os.path.realpath(p) == here:
        print(e.get("version", ""))
        break
PYEOF
}

plugin_enabled() {
  [ -n "$(plugin_installed_version)" ] || return 1
  TARGET="$SETTINGS_REL" PLUGIN_KEY="$PLUGIN_KEY" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    d = json.load(open(os.environ["TARGET"]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("enabledPlugins", {}).get(os.environ["PLUGIN_KEY"]) is True else 1)
PYEOF
}


install_plugin_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "==> claude not on PATH — settings written, but the plugin isn't installed." >&2
    echo "    Install Claude Code, then run: claude plugin install $PLUGIN_KEY --scope $SCOPE" >&2
    return 0
  fi
  # The awesm marketplace hosts the harness AND its 3 dependency plugins
  # (caveman, claude-mem, ponytail), so this single add covers all four —
  # dependency resolution then installs them automatically.
  claude plugin marketplace add "$MARKETPLACE_REPO" >/dev/null 2>&1 || true
  echo "==> Installing $PLUGIN_KEY (+ dependencies) at --scope $SCOPE"
  # `claude plugin install` short-circuits on an existing install ("already
  # installed") and does NOT upgrade it. Re-running the installer after a release
  # therefore left the OLD version in place while the marketplace cache moved on —
  # the user runs the bootstrap, is told everything is installed, and is still on
  # last week's plugin. Worse, repeated installs can leave two versions enabled
  # side by side with no defined winner. So update first, and let install handle
  # the not-yet-installed case.
  # Plugin installs live in ~/.claude/plugins/installed_plugins.json, keyed by
  # project path and PINNED to a cached copy of one version. Deleting and
  # re-cloning the repo does not touch that record, so a "fresh" test is not
  # fresh: `claude plugin install` sees the old entry, prints "already installed",
  # and leaves the stale version in place while the marketplace has moved on.
  # `claude plugin update` needs a restart to apply and does not help an installer
  # that is about to hand over a session. So compare versions and, when they
  # differ, uninstall the stale copy before installing — that is the only thing
  # that reliably lands the current version in this run.
  want="$(cat "$HOME/.claude/plugins/marketplaces/awesm/plugins/$PLUGIN_NAME/.claude-plugin/plugin.json" 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
  have="$(plugin_installed_version)"
  if [ -n "$want" ] && [ -n "$have" ] && [ "$have" != "$want" ]; then
    echo "==> Installed $PLUGIN_KEY is [$have], marketplace has [$want] — replacing."
    # `uninstall` REFUSES while the plugin is enabled at project scope, and
    # merge_settings enabled it seconds ago — so drop the key first, uninstall,
    # install, then let merge_settings put it back at the end of this function.
    TARGET="$SETTINGS_REL" PLUGIN_KEY="$PLUGIN_KEY" python3 <<'PYEOF' 2>/dev/null || true
import json, os
t = os.environ["TARGET"]
try:
    with open(t) as f: data = json.load(f)
except Exception:
    raise SystemExit(0)
data.get("enabledPlugins", {}).pop(os.environ["PLUGIN_KEY"], None)
with open(t, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
PYEOF
    if ! claude plugin uninstall "$PLUGIN_KEY" 2>&1 | sed 's/^/    /'; then
      echo "   (uninstall did not succeed — continuing; the version report below is authoritative)" >&2
    fi
  fi
  if ! claude plugin install "$PLUGIN_KEY" --scope "$SCOPE"; then
    echo "!! 'claude plugin install $PLUGIN_KEY' failed — check marketplace access." >&2
    echo "   Settings were still written; fix access and re-run the install command." >&2
    return 1
  fi
  # Installed != enabled. Verify, and try once to enable it before giving up.
  if ! plugin_enabled; then
    echo "==> $PLUGIN_KEY is not loading — enabling it and its dependencies."
    # A dependency that is installed-but-disabled here stops the parent loading,
    # so enable the whole set, not just the parent.
    for dep in "caveman@awesm" "claude-mem@awesm" "ponytail@awesm" "$PLUGIN_KEY"; do
      claude plugin enable "$dep" >/dev/null 2>&1 || true
    done
  fi
  # Enablement was stripped above if we replaced a stale copy — put it back, and
  # re-assert the dependency keys, before reporting.
  merge_settings "$SETTINGS_REL"

  # Report the version live IN THIS PROJECT. Other projects pinned to other
  # versions are normal and none of this run's business.
  live="$(plugin_installed_version)"
  [ -n "$live" ] && echo "==> $PLUGIN_KEY $live is live in $(pwd)"

  if ! plugin_enabled; then
    echo "!! $PLUGIN_KEY is installed but not loading, so its slash commands do not" >&2
    echo "   exist and onboarding cannot run. Most often a DEPENDENCY is installed but" >&2
    echo "   disabled in this project — Claude Code reports that as \"not installed\"." >&2
    echo "   See the reason, then enable whatever it names:" >&2
    echo "     claude plugin list" >&2
    echo "     claude plugin enable caveman@awesm claude-mem@awesm ponytail@awesm" >&2
    return 1
  fi
}

# --- ensure a Hermes runtime exists on this machine ----------------------------
# Projects built with the AGENT harness are Hermes agent profiles, and testing one
# (/awesm-agent:local-deploy) needs a working `hermes`. Two supported shapes:
#   native — `hermes` already on PATH; nothing to do.
#   docker — the official image as a long-lived container named `hermes`, with the
#            host's ~/.hermes bind-mounted as its data dir, so profiles, .env files
#            and sessions live at the same host paths either way.
# Never fatal: the harness installs fine without Hermes, and a missing runtime only
# bites at local-deploy time, which re-checks and says so.
HERMES_IMAGE="nousresearch/hermes-agent:latest"
HERMES_CONTAINER="hermes"
ensure_hermes() {
  # Only the agent harness builds Hermes profiles — co-pilot projects never need
  # a Hermes runtime, so don't pull a container onto those machines.
  if [ "$PLUGIN_NAME" != "awesm-agent" ]; then
    return 0
  fi
  if command -v hermes >/dev/null 2>&1; then
    echo "==> Hermes found on PATH — using the native install."
    return 0
  fi
  # ~/.hermes must belong to YOU. An earlier container run without --user leaves it
  # owned by the image's uid 10000, mode 700: the human is locked out of their own
  # data dir, and a container now running as the host user cannot write it either.
  # `mkdir -p` on such a directory succeeds silently and repairs nothing, so check.
  if [ -d "$HOME/.hermes" ] && [ ! -w "$HOME/.hermes" ]; then
    echo "!! ~/.hermes exists but you cannot write to it" >&2
    echo "   ($(stat -c '%U (uid %u) %A' "$HOME/.hermes" 2>/dev/null || stat -f '%Su %Sp' "$HOME/.hermes"))." >&2
    echo "   A previous Hermes container ran as its own uid and took the directory." >&2
    echo "   Take it back, then re-run init.sh:" >&2
    echo "     sudo chown -R \$(id -u):\$(id -g) ~/.hermes && chmod u+rwx ~/.hermes" >&2
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "==> Hermes isn't installed here, and neither is Docker."
    case "$PKG" in
      brew)
        echo "!! Docker Desktop is a GUI app on macOS and cannot be installed from here." >&2
        echo "   Install it from https://docs.docker.com/desktop/setup/install/mac-install/" >&2
        echo "   then re-run init.sh." >&2
        return 1 ;;
      dnf|yum)  pkg_install - moby-engine - - || pkg_install - docker - - || return 1 ;;
      apt)      pkg_install - - docker.io - || return 1 ;;
      apk)      pkg_install - - - docker || return 1 ;;
      *)        echo "!! No known way to install Docker here. https://docs.docker.com/get-docker/" >&2; return 1 ;;
    esac
    if have systemctl; then
      if [ "$INTERACTIVE" -eq 1 ] || [ -z "$SUDO" ]; then
        $SUDO systemctl enable --now docker || true
      else
        echo "   Then start it:  $SUDO systemctl enable --now docker" >&2
      fi
    fi
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
      echo "   And put yourself in the docker group (takes effect at your NEXT login):" >&2
      echo "     $SUDO usermod -aG docker $USER" >&2
      echo "   Until then, docker commands need sudo — re-run init.sh after logging in again." >&2
      return 1
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "==> Docker is installed but not reachable." >&2
    if have systemctl && ! systemctl is-active --quiet docker 2>/dev/null; then
      echo "   The daemon is stopped:  $SUDO systemctl enable --now docker" >&2
    fi
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
      echo "   You are not in the docker group:  $SUDO usermod -aG docker $USER" >&2
      echo "   (log out and back in for it to apply)" >&2
    fi
    echo "   Fix the above, then re-run init.sh to bring Hermes up." >&2
    return 1
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$HERMES_CONTAINER"; then
    echo "==> Hermes container '$HERMES_CONTAINER' already running."
    return 0
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$HERMES_CONTAINER"; then
    echo "==> Starting the existing Hermes container…"
    docker start "$HERMES_CONTAINER" >/dev/null && return 0
    echo "!! Could not start the existing '$HERMES_CONTAINER' container." >&2
    return 1
  fi

  echo "==> No Hermes on this machine — bringing up $HERMES_IMAGE"
  # ~/.hermes is bind-mounted as the container's data dir. The image's own user is
  # uid 10000, so left alone the container writes files the human cannot read: mode
  # 700, uid 10000, and the native CLI then dies reading ~/.hermes/.container-mode.
  #
  # Do NOT fix that with --user. The image REFUSES an arbitrary uid and exits 1 in a
  # restart loop: "container started with --user 1001 (an arbitrary, non-hermes UID)
  # — not supported", because it breaks the s6 supervision tree. It remaps its own
  # hermes user instead when given HERMES_UID/HERMES_GID, and chowns the data volume
  # at boot — same ownership outcome, container actually starts.
  mkdir -p "$HOME/.hermes"
  docker pull "$HERMES_IMAGE" || { echo "!! Could not pull $HERMES_IMAGE." >&2; return 1; }
  if ! docker run -d \
      --name "$HERMES_CONTAINER" \
      --restart unless-stopped \
      -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
      -v "$HOME/.hermes:/opt/data" \
      -p 8642:8642 \
      "$HERMES_IMAGE" gateway run >/dev/null; then
    echo "!! Could not start the Hermes container." >&2
    return 1
  fi
  # `docker run -d` returns 0 as soon as the container is CREATED — it says nothing
  # about whether the process inside survived. A container that rejects its own
  # arguments exits 1 and, with --restart unless-stopped, loops forever while every
  # caller reports success. That is exactly how an unsupported flag went unnoticed.
  # Verify it is actually running, and surface the container's own words if not.
  sleep 3
  hstate="$(docker inspect -f '{{.State.Status}}' "$HERMES_CONTAINER" 2>/dev/null || echo unknown)"
  if [ "$hstate" != "running" ]; then
    echo "!! Hermes container is '$hstate', not running — it started and died." >&2
    echo "   Last lines from the container:" >&2
    docker logs --tail 15 "$HERMES_CONTAINER" 2>&1 | sed 's/^/     /' >&2
    echo "   Fix the cause above, then re-run. Leaving the container in place so the" >&2
    echo "   logs stay readable: 'docker rm -f $HERMES_CONTAINER' to start over." >&2
    return 1
  fi
  echo "==> Hermes container '$HERMES_CONTAINER' is up (API on :8642)."

  # First-run config. Hermes ships `setup --non-interactive` ("use defaults/env
  # vars"), so the wizard was never mandatory — the harness simply never used the
  # flag, and every user was made to sit through it. Run it non-interactively here.
  #
  # Note what this layer is: the ROOT/default profile. /awesm-agent:local-deploy
  # installs the agent as its own `<slug>-local` profile, which carries its own
  # config.yaml (model pinned) and its own .env — and Hermes resolves env per
  # profile, so a profile never reads the root .env. Configuring the root by hand
  # therefore sets something the agent does not read. Whether the agent can
  # actually think is doctor's call, against the installed profile.
  if docker exec "$HERMES_CONTAINER" hermes setup --non-interactive >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Hermes is up, but 'hermes setup --non-interactive' did not succeed." >&2
  echo "    Run the wizard yourself to see what it wants:" >&2
  echo "      docker exec -it $HERMES_CONTAINER hermes setup" >&2
  return 10
}

# --- launch Claude Code + onboarding -------------------------------------------
# Launching an interactive Claude Code session needs a real terminal AND must
# not be nested inside an existing one. Two problem cases the naive `exec
# claude` got wrong:
#   1. Already inside a Claude session (CLAUDECODE set) — pasting the curl line
#      into the Claude prompt, or running it via `!`. Spawning a nested
#      interactive claude here hangs/breaks. Print instructions instead.
#   2. `curl ... | bash` — stdin is the pipe, and a Claude session launched from
#      a pipe can't answer its own startup prompts (it freezes). So do NOT
#      auto-launch when piped; print the command for the user to run instead.
# The command is the PLUGIN-NAMESPACED /$PLUGIN_NAME:onboard — a plugin's slash
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
    # One-command flow: hand the user a session that is ALREADY onboarding. This is
    # the whole point of the installer, so it is restored rather than dropped.
    #
    # It is gated on the plugin actually being ENABLED, because that — not the
    # dispatch — is what broke before: a plugin installed but left disabled has no
    # slash commands, so /<plugin>:onboard is an unknown command however it is
    # invoked, typed or dispatched. When it is not enabled we do not pretend:
    # hand over a plain session and say what to fix. exec replaces this process,
    # so anything worth printing must be printed first.
    echo
    echo "==> Installed. Ready at: $(pwd)"
    if plugin_enabled; then
      echo "    Opening Claude Code and starting onboarding."
      exec claude "/$PLUGIN_NAME:onboard"
    fi
    echo "    $PLUGIN_KEY is not enabled, so /$PLUGIN_NAME:onboard does not exist yet."
    echo "    Fix it, then run the command yourself:"
    echo "      claude plugin enable $PLUGIN_KEY"
    echo "      /$PLUGIN_NAME:onboard"
    exec claude
  else
    # Piped install (curl | bash): do NOT auto-launch. Even reconnecting /dev/tty,
    # an interactive Claude launched from a pipe cannot reliably take input at its
    # startup prompts (MCP trust / permission approvals) and appears frozen —
    # confirmed the hard way. Industry standard: a piped installer sets up, then
    # prints the next command; the user opens Claude in a real terminal where the
    # prompts work. Local runs ([ -t 0 ] above) still auto-launch.
    echo "==> Installed — open Claude Code yourself to start onboarding (see below)."
  fi
  echo
  echo "==> Installed. Ready at: $(pwd)"
  echo "    Copy and run this one line to start onboarding:"
  if [ -n "$cd_hint" ]; then
    echo "      cd '$cd_hint' && claude \"/$PLUGIN_NAME:onboard\""
  else
    echo "      claude \"/$PLUGIN_NAME:onboard\""
  fi
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

  ensure_hermes || true

  echo "==> '$PROJECT_NAME' is ready."
  launch_claude_onboard "$PROJECT_NAME"

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

  # BOTH awesm plugins enabled is the failure the marker loop above does not catch: it looks
  # for a project's OWN .claude machinery, not for the other harness. A project that adopted
  # the co-pilot and is now handed --agent (or the reverse) ends up with both in
  # enabledPlugins, and they are not complementary — each ships commit-gate.sh,
  # state-handler-reminder.sh and the graphify hooks on PreToolUse Bash, so every one of them
  # fires twice. Observed on a real repo, not hypothetical. Refuse and name the fix; do not
  # silently add the second.
  OTHER_PLUGIN="awesm-harness"
  [ "$PLUGIN_NAME" = "awesm-harness" ] && OTHER_PLUGIN="awesm-agent"
  SETTINGS_PROBE="$(settings_path_for_scope "$SCOPE")"
  if [ -f "$SETTINGS_PROBE" ] && grep -q "\"${OTHER_PLUGIN}@awesm\"[[:space:]]*:[[:space:]]*true" "$SETTINGS_PROBE" 2>/dev/null; then
    echo "!! This project already has '$OTHER_PLUGIN' enabled in $SETTINGS_PROBE, and you are" >&2
    echo "   installing '$PLUGIN_NAME'. A project runs exactly ONE of the two: they duplicate" >&2
    echo "   every shared hook (commit-gate, state-handler-reminder, the graphify nudges), so" >&2
    echo "   enabling both makes each fire twice on every command." >&2
    echo >&2
    echo "   Pick one and remove the other from enabledPlugins in that file, then re-run:" >&2
    echo "     awesm-agent   — this project BUILDS a Hermes agent (it has a profile/ directory)" >&2
    echo "     awesm-harness — everyday co-pilot work (web app, automation tool, marketing)" >&2
    exit 1
  fi

  if [ -d .git ]; then
    # Ignore the settings file THIS INSTALLER writes. It was tripping on its own output: a
    # first run writes .claude/settings.json, and every run after that sees a dirty tree and
    # refuses, so the installer could never be re-run until someone committed the file it had
    # just created. The gate exists to protect the USER's uncommitted work, which this is not.
    dirty="$(git status --porcelain -- . 2>/dev/null \
             | awk '$2 != ".claude/settings.json" && $NF != ".claude/settings.json"' \
             | grep -v '^??' || true)"
    if [ -n "$dirty" ]; then
      echo "!! You have uncommitted changes here. Commit or stash them first so this" >&2
      echo "   step (and everything /onboard adds later) stays cleanly revertible:" >&2
      printf '%s\n' "$dirty" | sed 's/^/     /' >&2
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
  ensure_hermes || true
  echo "==> Done."

  launch_claude_onboard ""
fi
