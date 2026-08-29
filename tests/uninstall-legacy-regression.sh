#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/skill-q-uninstall-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export SKILL_Q_STATE_DIR="$TMP/state"
OLD="$TMP/deleted-old-checkout"
FOREIGN="$TMP/foreign"
mkdir -p \
  "$HOME/.claude/skills" \
  "$HOME/.codex/skills" \
  "$HOME/.config/opencode/skills/y-example" \
  "$HOME/.config/opencode/commands" \
  "$FOREIGN/y-example"

# y-example was shipped by early skill-q commits and then removed when the repo
# switched to q-* naming. Its old checkout no longer exists here.
ln -s "$OLD/commands/y-example" "$HOME/.claude/skills/y-example"
ln -s "$OLD/opencode-commands/y-example.md" "$HOME/.config/opencode/commands/y-example.md"

# Historical name alone never authorizes deleting a live foreign skill.
printf '%s\n' '# user-owned y-example' > "$FOREIGN/y-example/SKILL.md"
ln -s "$FOREIGN/y-example" "$HOME/.codex/skills/y-example"

ln -s "$OLD/commands/not-from-skill-q" "$HOME/.claude/skills/not-from-skill-q"

# A copied historical skill needs the generated repository header as ownership
# proof before uninstall may remove it.
cat > "$HOME/.config/opencode/skills/y-example/SKILL.md" <<'EOF'
<!-- generated -->
skill-q repository
bin/update-check
EOF

printf '# skill-q-managed-command\n' > "$HOME/.config/opencode/commands/old-managed.md"
printf '# user command\n' > "$HOME/.config/opencode/commands/user.md"

bash "$ROOT/uninstall.sh" --yes >/dev/null

[[ ! -L "$HOME/.claude/skills/y-example" ]]
[[ -L "$HOME/.codex/skills/y-example" ]]
[[ -L "$HOME/.claude/skills/not-from-skill-q" ]]
[[ ! -e "$HOME/.config/opencode/skills/y-example" ]]
[[ ! -L "$HOME/.config/opencode/commands/y-example.md" ]]
[[ ! -e "$HOME/.config/opencode/commands/old-managed.md" ]]
[[ -e "$HOME/.config/opencode/commands/user.md" ]]

echo 'legacy uninstall regression: ok'
