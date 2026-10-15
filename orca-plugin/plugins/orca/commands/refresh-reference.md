---
description: Regenerate the orca skill's bundled command reference from your installed Orca version
---

Regenerate the bundled CLI reference so it matches the Orca installed on this machine.

1. Run `"${CLAUDE_PLUGIN_ROOT}/skills/orca/scripts/orca.sh" --version` to show which Orca
   build will be used.
2. Run `python3 "${CLAUDE_PLUGIN_ROOT}/skills/orca/scripts/build_reference.py"`. It calls
   `orca agent-context --json`, which works even when the Orca app is closed.
3. Report the command count and the diff summary (`git diff --stat` if the plugin directory is a
   git checkout). Mention that changes made in an installed plugin cache can be overwritten by
   plugin updates; to keep them, run this in the source checkout of the plugin.
