# awesm harness installer

Public bootstrap script for the private awesm Claude Code marketplace. The plugin source lives in `awesm-dev/awesm-claude-harness`; the Hermes builder plugin lives in `awesm-dev/agent-builder-harness`. Access to those private repositories is required.

## Install

Install Claude Code first. Run from a terminal so the GitHub login flow can use it:

```bash
# New staff project
bash <(curl -fsSL https://raw.githubusercontent.com/awesm-dev/awesm-harness-installation/main/install.sh) my-project

# New Hermes agent project
bash <(curl -fsSL https://raw.githubusercontent.com/awesm-dev/awesm-harness-installation/main/install.sh) my-agent --agent
```

For an existing project, run inside its directory and omit the project name. The installer checks adoption conflicts, sets up GitHub access and plugin installation, then opens Claude Code. Accept project trust and follow the displayed `/awesm-harness:onboard` or `/awesm-agent:onboard` instruction; restart Claude if commands are not yet registered. Already-onboarded projects are directed to harness update.

The installer runs on the user's machine. This repository does not host a server or database. Maintain it in sync with `scripts/install.sh` in the private marketplace repository; never copy credentials or private configuration into this public repository.
