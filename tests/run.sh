#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/skill-q-tests.XXXXXX")" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Keep the suite hermetic: never let locally installed agents decide which
# code paths the scripts take. Detection and selection tests override these.
export SKILL_Q_OPENCODE_VERSION=v1
export SKILL_Q_AGENTS=claude,codex,opencode

# shellcheck source=lib/harness.sh
source "$PROJECT_ROOT/tests/lib/harness.sh"
skill_q_test_parse_args "$@"

# The harness itself: a test that never returns must be terminated and reported
# as a failure, otherwise a worktree lock or a stalled subprocess silently eats
# the whole session. The fixture suite is bounded to a two-second timeout.
test_harness_terminates_a_stalled_test() {
  local output
  if output=$(SKILL_Q_TEST_TIMEOUT=2 bash "$PROJECT_ROOT/tests/lib/timeout-fixture.sh" 2>&1); then
    printf '%s\n' "$output" >&2
    echo 'stalled test fixture unexpectedly succeeded' >&2
    return 1
  fi
  rg -q 'TIMEOUT after 2s' <<<"$output"
  rg -q '1 failed' <<<"$output"
}

test_build_registry_publishes_self_contained_skills() {
  local project="$TEST_ROOT/registry"
  copy_project "$project"
  mkdir -p "$project/commands-src/demo/scripts"
  cat > "$project/commands-src/demo/SKILL.md" <<'EOF'
---
name: demo
description: fixture
---

# Demo body

## Provenance

Where this skill came from.

### Detail

More maintenance history.

## Keep

Kept section.
EOF
  echo 'echo helper' > "$project/commands-src/demo/scripts/helper.sh"
  chmod +x "$project/commands-src/demo/scripts/helper.sh"

  "$project/bin/build-registry.sh" >/dev/null
  local published="$project/skills/demo/SKILL.md"
  rg -q '^# Demo body$' "$published"

  # Provenance is repository maintenance history, so it never reaches the
  # published skill; skipping stops at the next H2 rather than at EOF.
  ! rg -q 'Provenance|maintenance history|^### Detail$' "$published"
  rg -q '^## Keep$' "$published"
  rg -q '^Kept section\.$' "$published"

  # The npx surface deliberately omits the checkout-only update-check header:
  # an installed skill has no skill-q repository above it.
  ! rg -q '此區塊由 bin/build.sh' "$published"

  # Support files are materialized, executable bits included, so a single
  # `--skill demo` install is self-contained.
  cmp "$project/commands-src/demo/scripts/helper.sh" "$project/skills/demo/scripts/helper.sh"
  [[ -x "$project/skills/demo/scripts/helper.sh" ]]

  # A second build is deterministic and leaves the tree in sync.
  cp -a "$project/skills" "$project/first-registry"
  "$project/bin/build-registry.sh" >/dev/null
  diff -ru "$project/first-registry" "$project/skills"
  "$project/bin/build-registry.sh" --check >/dev/null
}

test_build_registry_check_detects_drift() {
  local project="$TEST_ROOT/registry-drift"
  copy_project "$project"
  "$project/bin/build-registry.sh" >/dev/null
  "$project/bin/build-registry.sh" --check >/dev/null

  # An edited source without a rebuild.
  printf '\nDrifted.\n' >> "$project/commands-src/example-skill/SKILL.md"
  if "$project/bin/build-registry.sh" --check >/dev/null 2>"$project/stale"; then
    return 1
  fi
  rg -q 'Published skills/ is stale' "$project/stale"
  "$project/bin/build-registry.sh" >/dev/null

  # A published skill whose source is gone.
  mkdir -p "$project/skills/ghost"
  echo 'stale' > "$project/skills/ghost/SKILL.md"
  if "$project/bin/build-registry.sh" --check >/dev/null 2>&1; then
    return 1
  fi
  rm -rf "$project/skills/ghost"

  # Content can match while the executable bit does not.
  mkdir -p "$project/commands-src/example-skill/scripts"
  echo 'echo helper' > "$project/commands-src/example-skill/scripts/helper.sh"
  chmod +x "$project/commands-src/example-skill/scripts/helper.sh"
  "$project/bin/build-registry.sh" >/dev/null
  chmod -x "$project/skills/example-skill/scripts/helper.sh"
  if "$project/bin/build-registry.sh" --check >/dev/null 2>"$project/modes"; then
    return 1
  fi
  rg -q 'file-mode drift' "$project/modes"
}

test_build_registry_rejects_invalid_frontmatter_without_destroying_output() {
  local project="$TEST_ROOT/registry-invalid"
  copy_project "$project"
  "$project/bin/build-registry.sh" >/dev/null
  cp -a "$project/skills" "$project/expected-skills"

  # A body-only file is reported as invalid frontmatter, not as a name
  # mismatch against an empty name.
  printf '# missing frontmatter\n\n---\n' > "$project/commands-src/example-skill/SKILL.md"
  if "$project/bin/build-registry.sh" >/dev/null 2>"$project/stderr"; then
    return 1
  fi
  rg -q 'Invalid frontmatter' "$project/stderr"

  # Staging means a rejected build never touches the published tree.
  diff -ru "$project/expected-skills" "$project/skills"

  # A folder that disagrees with frontmatter `name:` is rejected too.
  cat > "$project/commands-src/example-skill/SKILL.md" <<'EOF'
---
name: renamed
description: fixture
---

# Body
EOF
  if "$project/bin/build-registry.sh" >/dev/null 2>"$project/mismatch"; then
    return 1
  fi
  rg -q 'Skill name mismatch' "$project/mismatch"
  diff -ru "$project/expected-skills" "$project/skills"
}

test_build_injects_header_and_support_files() {
  local project="$TEST_ROOT/build"
  copy_project "$project"
  mkdir -p "$project/commands-src/demo/scripts"
  cat > "$project/commands-src/demo/SKILL.md" <<'EOF'
---
name: demo
description: fixture
---

# Demo body
EOF
  echo 'echo helper' > "$project/commands-src/demo/scripts/helper.sh"

  "$project/bin/build.sh" >/dev/null
  [[ $(rg -c '此區塊由 bin/build.sh' "$project/commands/demo/SKILL.md") -eq 1 ]]
  rg -q '^# Demo body$' "$project/commands/demo/SKILL.md"
  cmp "$project/commands-src/demo/scripts/helper.sh" "$project/commands/demo/scripts/helper.sh"

  # A second build must be deterministic and must not inject the header twice.
  cp -a "$project/commands" "$project/first-build"
  cp -a "$project/opencode-commands" "$project/first-build-commands"
  "$project/bin/build.sh" >/dev/null
  diff -ru "$project/first-build" "$project/commands"
  diff -ru "$project/first-build-commands" "$project/opencode-commands"
}

test_build_generates_opencode_command_shims() {
  local project="$TEST_ROOT/shims"
  copy_project "$project"
  mkdir -p "$project/commands-src/demo"
  cat > "$project/commands-src/demo/SKILL.md" <<'EOF'
---
name: demo
description: Fixture that doesn't lose its apostrophe.
---

# Demo body
UNIQUE-CANONICAL-SENTINEL
EOF

  "$project/bin/build.sh" >/dev/null
  local shim="$project/opencode-commands/demo.md"
  [[ -f "$shim" ]]
  [[ -f "$project/opencode-commands/example-skill.md" ]]

  # The frontmatter description is carried over with YAML-safe quoting.
  rg -q "^description: 'Fixture that doesn''t lose its apostrophe\.'$" "$shim"
  # The shim delegates to the canonical skill and forwards arguments.
  rg -qF 'Use the `skill` tool to load the `demo` skill' "$shim"
  rg -qF '$ARGUMENTS' "$shim"
  # It must not duplicate the canonical instructions or the update-check header.
  ! rg -q 'UNIQUE-CANONICAL-SENTINEL' "$shim"
  ! rg -q '此區塊由 bin/build.sh' "$shim"
}

test_opencode_version_detection() {
  local project="$TEST_ROOT/version"
  local fake="$TEST_ROOT/version-bin"
  copy_project "$project"
  mkdir -p "$fake"

  fake_opencode() {
    printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$fake/opencode"
    chmod +x "$fake/opencode"
  }

  fake_opencode 1.18.16
  [[ $(PATH="$fake:$PATH" SKILL_Q_OPENCODE_VERSION=auto "$project/bin/opencode-version.sh") == v1 ]]
  fake_opencode 2.0.3
  [[ $(PATH="$fake:$PATH" SKILL_Q_OPENCODE_VERSION=auto "$project/bin/opencode-version.sh") == v2 ]]

  # An explicit override wins over whatever is installed.
  [[ $(PATH="$fake:$PATH" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/opencode-version.sh") == v1 ]]

  # Without a detectable binary the installer stays useful and says so.
  rm "$fake/opencode"
  local output
  output=$(PATH="$fake:/usr/bin:/bin" SKILL_Q_OPENCODE_VERSION=auto "$project/bin/opencode-version.sh" 2>"$project/detect-stderr")
  [[ "$output" == v1 ]]
  rg -q 'SKILL_Q_OPENCODE_VERSION' "$project/detect-stderr"

  # An unusable value fails loudly instead of guessing.
  if SKILL_Q_OPENCODE_VERSION=v3 "$project/bin/opencode-version.sh" >/dev/null 2>&1; then
    return 1
  fi
}

test_sync_installs_opencode_v1_commands() {
  local project="$TEST_ROOT/opencode-v1"
  local home="$TEST_ROOT/opencode-v1-home"
  local commands="$home/.config/opencode/commands"
  copy_built_project "$project"
  mkdir -p "$commands"
  echo 'user owned' > "$commands/example-skill.md"
  cp "$project/opencode-commands/funny-text-rewriter.md" "$commands/funny-text-rewriter.md"

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/sync-skills.sh" >/dev/null 2>"$project/warnings"
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/sync-skills.sh" >/dev/null 2>>"$project/warnings"

  # A pre-existing non-managed command is never overwritten.
  [[ ! -L "$commands/example-skill.md" ]]
  [[ $(cat "$commands/example-skill.md") == 'user owned' ]]
  rg -q 'skipping unowned non-symlink path' "$project/warnings"

  # Everything else is linked once, idempotently, at the canonical shim.
  [[ -L "$commands/funny-text-rewriter.md" ]]
  [[ "$(realpath -- "$(readlink "$commands/funny-text-rewriter.md")")" == \
     "$(realpath -- "$project/opencode-commands/funny-text-rewriter.md")" ]]
  [[ $(find "$commands" -mindepth 1 -maxdepth 1 -name 'funny-text-rewriter.md' | wc -l) -eq 1 ]]
  # A copied shim managed by skill-q is safely converted to the local symlink form.
  [[ -L "$commands/funny-text-rewriter.md" ]]
  [[ "$(realpath -- "$(readlink "$commands/funny-text-rewriter.md")")" == \
     "$(realpath -- "$project/opencode-commands/funny-text-rewriter.md")" ]]
}

test_sync_removes_stale_opencode_commands() {
  local project="$TEST_ROOT/opencode-stale"
  local home="$TEST_ROOT/opencode-stale-home"
  local commands="$home/.config/opencode/commands"
  copy_project "$project"
  mkdir -p "$project/commands-src/temp-skill"
  cat > "$project/commands-src/temp-skill/SKILL.md" <<'EOF'
---
name: temp-skill
description: fixture
---

body
EOF
  "$project/bin/build.sh" >/dev/null
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/sync-skills.sh" >/dev/null
  [[ -L "$commands/temp-skill.md" ]]

  rm -rf "$project/commands-src/temp-skill"
  "$project/bin/build.sh" >/dev/null
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/sync-skills.sh" >/dev/null 2>/dev/null

  [[ ! -e "$commands/temp-skill.md" ]]
  [[ -L "$commands/example-skill.md" ]]
}

test_sync_v2_removes_generated_commands() {
  local project="$TEST_ROOT/opencode-v2"
  local home="$TEST_ROOT/opencode-v2-home"
  local commands="$home/.config/opencode/commands"
  copy_built_project "$project"
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 "$project/bin/sync-skills.sh" >/dev/null
  echo 'user owned' > "$commands/user-command.md"

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v2 "$project/bin/sync-skills.sh" >/dev/null 2>/dev/null

  # v2 lists skills natively, so generated shims must not linger as duplicates.
  [[ ! -e "$commands/example-skill.md" ]]
  [[ ! -e "$commands/funny-text-rewriter.md" ]]
  [[ -f "$commands/user-command.md" ]]
  # Skills themselves stay synchronized.
  [[ -L "$home/.config/opencode/skills/example-skill" ]]
}

test_build_rejects_invalid_frontmatter_without_destroying_output() {
  local project="$TEST_ROOT/invalid-build"
  copy_project "$project"
  "$project/bin/build.sh" >/dev/null
  cp -a "$project/commands" "$project/expected"
  cp -a "$project/opencode-commands" "$project/expected-commands"
  printf '# missing frontmatter\n' > "$project/commands-src/example-skill/SKILL.md"

  if "$project/bin/build.sh" >"$project/stdout" 2>"$project/stderr"; then
    return 1
  fi
  rg -q 'Invalid frontmatter' "$project/stderr"
  diff -ru "$project/expected" "$project/commands"
  diff -ru "$project/expected-commands" "$project/opencode-commands"
}

test_build_accepts_crlf_frontmatter() {
  local project="$TEST_ROOT/crlf"
  copy_project "$project"
  printf -- '---\r\nname: crlf-skill\r\ndescription: fixture\r\n---\r\n\r\nbody\r\n' \
    > "$project/commands-src/example-skill/SKILL.md"

  "$project/bin/build.sh" >/dev/null
  rg -q '^name: crlf-skill$' "$project/commands/example-skill/SKILL.md"
  ! rg -q $'\r' "$project/commands/example-skill/SKILL.md"
}

test_sync_removes_links_for_deleted_skills() {
  local project="$TEST_ROOT/sync-remove"
  local home="$TEST_ROOT/sync-remove-home"
  copy_project "$project"
  mkdir -p "$project/commands-src/second-skill"
  cat > "$project/commands-src/second-skill/SKILL.md" <<'EOF'
---
name: second-skill
description: fixture
---

body
EOF
  "$project/bin/build.sh" >/dev/null
  HOME="$home" "$project/bin/sync-skills.sh" >/dev/null

  rm -rf "$project/commands-src/second-skill"
  "$project/bin/build.sh" >/dev/null
  HOME="$home" "$project/bin/sync-skills.sh" >/dev/null

  [[ -L "$home/.claude/skills/example-skill" ]]
  [[ ! -e "$home/.claude/skills/second-skill" ]]
}

test_sync_is_idempotent_and_preserves_collisions() {
  local project="$TEST_ROOT/sync"
  local home="$TEST_ROOT/sync-home"
  copy_built_project "$project"
  mkdir -p "$home/.claude/skills/example-skill"
  echo keep > "$home/.claude/skills/example-skill/user-file"

  HOME="$home" "$project/bin/sync-skills.sh" >/dev/null 2>"$project/warnings"
  HOME="$home" "$project/bin/sync-skills.sh" >/dev/null 2>>"$project/warnings"
  [[ -f "$home/.claude/skills/example-skill/user-file" ]]
  for path in \
    .codex/skills/example-skill \
    .agents/skills/example-skill \
    .config/opencode/skills/example-skill; do
    [[ -L "$home/$path" ]]
    [[ $(readlink "$home/$path") == "$project/commands/example-skill" ]]
  done
  rg -q 'skipping unowned non-symlink path' "$project/warnings"
}

make_git_fixture() {
  local project=$1
  local remote=$2
  copy_built_project "$project"
  git init -q --bare "$remote"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial
  git -C "$project" remote add origin "$remote"
  git -C "$project" push -qu origin HEAD
}

test_update_check_states() {
  local project="$TEST_ROOT/update"
  local remote="$TEST_ROOT/update.git"
  local state="$TEST_ROOT/update-state"
  local other="$TEST_ROOT/update-other"
  make_git_fixture "$project" "$remote"

  [[ $(SKILL_Q_STATE_DIR="$state" "$project/bin/update-check") == UP_TO_DATE ]]

  git clone -q "$remote" "$other"
  git -C "$other" config user.email test@example.invalid
  git -C "$other" config user.name 'Test Runner'
  echo newer > "$other/new-file"
  git -C "$other" add new-file
  git -C "$other" commit -qm newer
  git -C "$other" push -q

  local output
  output=$(SKILL_Q_STATE_DIR="$state" SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$project/bin/update-check")
  [[ "$output" == UPGRADE_AVAILABLE* ]]

  SKILL_Q_STATE_DIR="$state" SKILL_Q_SNOOZE_DAYS=7 "$project/bin/snooze.sh" >/dev/null
  [[ $(SKILL_Q_STATE_DIR="$state" SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$project/bin/update-check") == UP_TO_DATE ]]
}

test_update_check_fails_open_without_remote() {
  local project="$TEST_ROOT/no-remote"
  local state="$TEST_ROOT/no-remote-state"
  copy_project "$project"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial

  [[ -z $(SKILL_Q_STATE_DIR="$state" "$project/bin/update-check") ]]
  [[ ! -e "$state/last-check" ]]
}

test_apply_update_fast_forwards_and_resyncs() {
  local project="$TEST_ROOT/apply"
  local remote="$TEST_ROOT/apply.git"
  local author="$TEST_ROOT/apply-author"
  local home="$TEST_ROOT/apply-home"
  local state="$TEST_ROOT/apply-state"
  make_git_fixture "$project" "$remote"
  git clone -q "$remote" "$author"
  git -C "$author" config user.email test@example.invalid
  git -C "$author" config user.name 'Test Runner'
  echo update > "$author/update-marker"
  git -C "$author" add update-marker
  git -C "$author" commit -qm update
  git -C "$author" push -q
  mkdir -p "$state"
  : > "$state/last-check"
  : > "$state/snooze-until"

  HOME="$home" SKILL_Q_STATE_DIR="$state" "$project/bin/apply-update.sh" >/dev/null
  [[ -f "$project/update-marker" ]]
  [[ -L "$home/.codex/skills/example-skill" ]]
  [[ ! -e "$state/last-check" && ! -e "$state/snooze-until" ]]
}

test_cloud_bootstrap_copies_pinned_content() {
  local project="$TEST_ROOT/cloud-source"
  local remote="$TEST_ROOT/cloud.git"
  local home="$TEST_ROOT/cloud-home"
  make_git_fixture "$project" "$remote"
  local ref
  ref=$(git -C "$project" rev-parse HEAD)

  HOME="$home" "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null
  for path in \
    .claude/skills/example-skill \
    .codex/skills/example-skill \
    .agents/skills/example-skill \
    .config/opencode/skills/example-skill; do
    [[ -f "$home/$path/SKILL.md" ]]
    [[ ! -L "$home/$path" ]]
  done
}

test_cloud_bootstrap_installs_command_shims() {
  local project="$TEST_ROOT/cloud-commands-source"
  local remote="$TEST_ROOT/cloud-commands.git"
  local home="$TEST_ROOT/cloud-commands-home"
  local commands="$home/.config/opencode/commands"
  make_git_fixture "$project" "$remote"
  local ref
  ref=$(git -C "$project" rev-parse HEAD)
  mkdir -p "$commands"
  echo 'user owned' > "$commands/example-skill.md"
  # A reused image layer or HOME still holds the symlinks an earlier managed
  # sync created. Those are recorded in the manifest, so the pinned copy is
  # allowed to unlink them; anything unmanaged is not touched.
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 SKILL_Q_AGENTS=opencode \
    "$project/bin/skill-q" install >/dev/null 2>&1
  [[ -L "$commands/funny-text-rewriter.md" ]]

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null 2>"$project/cloud-warnings"

  # Pinned images get copies, not links, and never clobber a user's own command.
  [[ -f "$commands/funny-text-rewriter.md" && ! -L "$commands/funny-text-rewriter.md" ]]
  [[ -f "$commands/funny-text-rewriter.md" && ! -L "$commands/funny-text-rewriter.md" ]]
  rg -qF '$ARGUMENTS' "$commands/funny-text-rewriter.md"
  [[ $(cat "$commands/example-skill.md") == 'user owned' ]]
  rg -q 'non-managed command' "$project/cloud-warnings"

  # v2 images rely on the native slash catalog instead.
  local home_v2="$TEST_ROOT/cloud-commands-home-v2"
  HOME="$home_v2" SKILL_Q_OPENCODE_VERSION=v2 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null
  [[ ! -e "$home_v2/.config/opencode/commands" ]]
  [[ -f "$home_v2/.config/opencode/skills/example-skill/SKILL.md" ]]
}

test_sync_new_canonical_consumer_from_targets_conf() {
  local project="$TEST_ROOT/new-consumer"
  local home="$TEST_ROOT/new-consumer-home"
  copy_built_project "$project"

  mkdir -p "$home/.my-custom-agent/skills"
  cat > "$project/bin/targets/targets.conf" <<'EOF'
# Target registry for bin/build.sh.

CANONICAL_DEST="commands"
CANONICAL_CONSUMERS=(
  "claude-code:~/.claude/skills"
  "codex:~/.codex/skills"
  "codex-defensive:~/.agents/skills"
  "opencode-v2:~/.config/opencode/skills"
  "my-custom-agent:~/.my-custom-agent/skills"
)

TRANSFORMED_TARGETS=(
  "opencode-v1-commands:opencode-commands"
)
EOF

  HOME="$home" "$project/bin/sync-skills.sh" >/dev/null

  [[ -L "$home/.my-custom-agent/skills/example-skill" ]]
  link_target=$(readlink "$home/.my-custom-agent/skills/example-skill")
  expected="$project/commands/example-skill"
  [[ "$(realpath -- "$link_target")" == "$(realpath -- "$expected")" ]]
}

test_cloud_v2_bootstrap_removes_managed_shims_preserves_user_files() {
  local project="$TEST_ROOT/cloud-v2-shims"
  local remote="$TEST_ROOT/cloud-v2-shims.git"
  local home="$TEST_ROOT/cloud-v2-shims-home"
  local commands="$home/.config/opencode/commands"
  make_git_fixture "$project" "$remote"
  local ref
  ref=$(git -C "$project" rev-parse HEAD)
  mkdir -p "$commands"
  cp "$project/opencode-commands/example-skill.md" "$commands/example-skill.md"
  echo 'user owned other' > "$commands/other-command.md"

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v2 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null 2>"$project/cloud-warnings"

  [[ ! -e "$commands/example-skill.md" ]]
  [[ ! -e "$commands/funny-text-rewriter.md" ]]
  [[ $(cat "$commands/other-command.md") == 'user owned other' ]]
  [[ -f "$home/.config/opencode/skills/example-skill/SKILL.md" ]]
}

# Regression for issue #13: build outputs are disposable gitignored
# artifacts, so a clean source-only checkout must produce them on demand
# and must not leave them as tracked changes.
test_build_outputs_are_gitignored_artifacts() {
  local project="$TEST_ROOT/source-only"
  copy_project "$project"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'

  # The .gitignore must list every disposable artifact produced by build.sh.
  rg -q '^commands/$' "$project/.gitignore"
  rg -q '^opencode-commands/$' "$project/.gitignore"

  "$project/bin/build.sh" >/dev/null
  [[ -d "$project/commands" ]]
  [[ -d "$project/opencode-commands" ]]

  git -C "$project" add .
  git -C "$project" commit -qm initial

  local status
  status=$(git -C "$project" status --short -- commands opencode-commands)
  [[ -z "$status" ]]

  # Editing a source skill must regenerate artifacts but never register
  # them as tracked modifications.
  printf '\nchanged body\n' >> "$project/commands-src/example-skill/SKILL.md"
  "$project/bin/build.sh" >/dev/null
  [[ -d "$project/commands" ]]
  status=$(git -C "$project" status --short -- commands opencode-commands)
  [[ -z "$status" ]]
}

# Regression for issue #13: a fresh source-only clone installs all
# supported skills and commands through install.sh alone.
test_install_from_source_only_checkout() {
  local project="$TEST_ROOT/source-install"
  local home="$TEST_ROOT/source-install-home"
  copy_project "$project"
  # Strip every artifact so install.sh has to build from scratch.
  rm -rf "$project/commands" "$project/opencode-commands"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial
  [[ ! -d "$project/commands" ]]
  [[ ! -d "$project/opencode-commands" ]]

  HOME="$home" "$project/install.sh" >/dev/null
  for path in \
    .claude/skills/example-skill \
    .codex/skills/example-skill \
    .agents/skills/example-skill \
    .config/opencode/skills/example-skill \
    .config/opencode/commands/example-skill.md; do
    [[ -e "$home/$path" ]]
  done
}

# Regression for issue #13: bin/apply-update.sh rebuilds artifacts after a
# successful fast-forward and before sync, so consumers never observe a
# stale tree from before the pull.
test_apply_update_rebuilds_after_pull() {
  local project="$TEST_ROOT/rebuild-update"
  local remote="$TEST_ROOT/rebuild-update.git"
  local author="$TEST_ROOT/rebuild-update-author"
  local home="$TEST_ROOT/rebuild-update-home"
  local state="$TEST_ROOT/rebuild-update-state"
  make_git_fixture "$project" "$remote"
  git clone -q "$remote" "$author"
  git -C "$author" config user.email test@example.invalid
  git -C "$author" config user.name 'Test Runner'

  # Author adds a brand new skill on a remote branch that hasn't been
  # built locally yet, then pushes it.
  mkdir -p "$author/commands-src/remote-skill"
  cat > "$author/commands-src/remote-skill/SKILL.md" <<'EOF'
---
name: remote-skill
description: fixture
---

body
EOF
  git -C "$author" add commands-src/remote-skill
  git -C "$author" commit -qm add-remote-skill
  git -C "$author" push -q

  # Sanity: local project only has commands-src/, no artifact tree.
  [[ ! -d "$project/commands/remote-skill" ]]

  mkdir -p "$state"
  : > "$state/last-check"

  HOME="$home" SKILL_Q_STATE_DIR="$state" \
    "$project/bin/apply-update.sh" >/dev/null

  # The new skill must be present in the artifact tree and symlinked
  # into every canonical consumer, because the rebuild happened.
  [[ -f "$project/commands/remote-skill/SKILL.md" ]]
  [[ -f "$project/opencode-commands/remote-skill.md" ]]
  [[ -L "$home/.claude/skills/remote-skill" ]]
  [[ -L "$home/.codex/skills/remote-skill" ]]
  [[ -L "$home/.agents/skills/remote-skill" ]]
  [[ -L "$home/.config/opencode/skills/remote-skill" ]]
  [[ -L "$home/.config/opencode/commands/remote-skill.md" ]]
}

# Regression for issue #13: a pinned ref that contains only canonical
# source plus build inputs must still produce a complete install, because
# cloud-bootstrap.sh builds before copying.
test_cloud_bootstrap_uses_source_only_ref() {
  local project="$TEST_ROOT/source-only-ref"
  local remote="$TEST_ROOT/source-only-ref.git"
  local home="$TEST_ROOT/source-only-ref-home"
  local bare="$TEST_ROOT/source-only-ref-bare.git"
  copy_project "$project"
  # Push a ref that has never been built: only source files are tracked.
  git init -q --bare "$bare"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial
  [[ ! -d "$project/commands" ]]
  [[ ! -d "$project/opencode-commands" ]]
  git -C "$project" remote add origin "$bare"
  git -C "$project" push -qu origin HEAD
  local ref
  ref=$(git -C "$project" rev-parse HEAD)

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 \
    "$project/bin/cloud-bootstrap.sh" "file://$bare" "$ref" >/dev/null
  for path in \
    .claude/skills/example-skill \
    .codex/skills/example-skill \
    .agents/skills/example-skill \
    .config/opencode/skills/example-skill \
    .config/opencode/commands/example-skill.md; do
    [[ -e "$home/$path" ]]
  done
  # Pinned installs copy artifacts rather than symlink them.
  [[ ! -L "$home/.claude/skills/example-skill" ]]
}

# ---------------------------------------------------------------------------
# Lifecycle CLI (bin/skill-q)
# ---------------------------------------------------------------------------

# A checkout plus a bare remote it tracks, already installed for one agent.
make_installed_fixture() {
  local project=$1 remote=$2 home=$3 agents=$4
  make_git_fixture "$project" "$remote"
  HOME="$home" SKILL_Q_AGENTS="$agents" "$project/bin/skill-q" install >/dev/null 2>&1
}

manifest_of() {
  # -print -quit rather than a pipe into head: the suite runs with pipefail and
  # a killed find would fail the caller.
  find "$1/.local/state/skill-q" -mindepth 2 -maxdepth 2 -name install.json -print -quit 2>/dev/null
}

test_init_installs_only_selected_agents() {
  local project="$TEST_ROOT/select"
  local home="$TEST_ROOT/select-home"
  copy_project "$project"

  HOME="$home" "$project/bin/skill-q" init --agents claude >/dev/null

  [[ -L "$home/.claude/skills/example-skill" ]]
  # Nothing is created for an agent the user did not select.
  [[ ! -e "$home/.codex" ]]
  [[ ! -e "$home/.agents" ]]
  [[ ! -e "$home/.config/opencode" ]]

  # An unknown agent is rejected instead of being silently ignored.
  if HOME="$home" "$project/bin/skill-q" init --agents nope >/dev/null 2>&1; then
    return 1
  fi
}

test_install_is_idempotent_and_records_a_manifest() {
  local project="$TEST_ROOT/idempotent"
  local home="$TEST_ROOT/idempotent home"   # a space proves the JSON round-trips
  copy_project "$project"

  HOME="$home" "$project/bin/skill-q" install --agents claude,opencode >/dev/null
  local manifest first
  manifest=$(manifest_of "$home")
  [[ -n "$manifest" ]]
  cp "$manifest" "$project/manifest-1.json"
  first=$(find "$home/.claude" "$home/.config/opencode" "$home/.local/state/skill-q" -mindepth 1 | sort)

  # An empty SKILL_Q_AGENTS falls through to the recorded selection.
  HOME="$home" SKILL_Q_AGENTS= "$project/bin/skill-q" install >/dev/null
  [[ "$(find "$home/.claude" "$home/.config/opencode" "$home/.local/state/skill-q" -mindepth 1 | sort)" == "$first" ]]

  # Only the timestamps may move between two identical installs.
  diff <(rg -v '"last_' "$project/manifest-1.json") <(rg -v '"last_' "$manifest")

  rg -q '"agents": \["claude", "opencode"\]' "$manifest"
  rg -q '"opencode_mode": "v1"' "$manifest"
  [[ "$(awk -f "$project/bin/lib/manifest.awk" -v mode=array -v key=skills "$manifest")" == \
     "$(find "$project/commands" -mindepth 2 -maxdepth 2 -type f -name SKILL.md | sed 's#/SKILL.md$##; s#.*/##' | sort)" ]]
  rg -qF "\"checkout_path\": \"$project\"" "$manifest"
  # Paths containing a space survive writing and reading the manifest.
  rg -qF "\"path\": \"$home/.claude/skills/example-skill\"" "$manifest"
  HOME="$home" "$project/bin/skill-q" doctor --strict >/dev/null
}

test_install_repairs_a_moved_checkout() {
  local project="$TEST_ROOT/moved"
  local moved="$TEST_ROOT/moved-elsewhere"
  local home="$TEST_ROOT/moved-home"
  copy_project "$project"
  git -C "$project" init -q
  HOME="$home" "$project/bin/skill-q" install --agents claude >/dev/null

  mv "$project" "$moved"

  # The stale absolute links must be identified, not just reported as broken.
  HOME="$home" "$moved/bin/skill-q" doctor > "$moved/doctor.txt" 2>&1 || true
  rg -q "checkout recorded at $project but running from $moved" "$moved/doctor.txt"
  rg -q 'STALE' "$moved/doctor.txt"
  if HOME="$home" "$moved/bin/skill-q" doctor --strict >/dev/null 2>&1; then
    return 1
  fi

  HOME="$home" SKILL_Q_AGENTS= "$moved/bin/skill-q" install >/dev/null
  HOME="$home" "$moved/bin/skill-q" doctor --strict >/dev/null
  [[ $(readlink "$home/.claude/skills/example-skill") == "$moved/commands/example-skill" ]]
}

test_sync_drops_deselected_agents() {
  local project="$TEST_ROOT/deselect"
  local home="$TEST_ROOT/deselect-home"
  copy_project "$project"
  HOME="$home" "$project/bin/skill-q" install --agents claude,opencode >/dev/null
  [[ -L "$home/.config/opencode/skills/example-skill" ]]
  mkdir -p "$home/.config/opencode/commands"
  echo 'user owned' > "$home/.config/opencode/commands/mine.md"

  HOME="$home" "$project/bin/skill-q" sync --agents claude >/dev/null 2>&1

  [[ -L "$home/.claude/skills/example-skill" ]]
  [[ ! -e "$home/.config/opencode/skills/example-skill" ]]
  [[ ! -e "$home/.config/opencode/commands/example-skill.md" ]]
  [[ -f "$home/.config/opencode/commands/mine.md" ]]
  HOME="$home" "$project/bin/skill-q" doctor --strict >/dev/null
}

test_status_reports_behind_and_stable_json() {
  local project="$TEST_ROOT/status"
  local remote="$TEST_ROOT/status.git"
  local home="$TEST_ROOT/status-home"
  local author="$TEST_ROOT/status-author"
  make_installed_fixture "$project" "$remote" "$home" claude

  HOME="$home" "$project/bin/skill-q" status --json > "$TEST_ROOT/status-current.json"
  rg -q '"state": "current"' "$TEST_ROOT/status-current.json"
  rg -q '"update_available": false' "$TEST_ROOT/status-current.json"

  # The JSON contract is the machine-readable surface; keep its shape pinned.
  diff <(rg -o '^  "[a-z_]+"' "$TEST_ROOT/status-current.json" | tr -d ' "') - <<'EOF'
schema
installation_id
checkout_path
recorded_checkout_path
checkout_moved
installed
repository_url
commit
branch
upstream
state
state_reason
behind
ahead
dirty
update_available
agents
agent_versions
opencode_mode
skills
paths
entries
EOF

  git clone -q "$remote" "$author"
  git -C "$author" config user.email test@example.invalid
  git -C "$author" config user.name 'Test Runner'
  echo later > "$author/later"
  git -C "$author" add later
  git -C "$author" commit -qm later
  git -C "$author" push -q

  # An out-of-date checkout must say so without waiting for a skill invocation,
  # which means fetching rather than trusting the local remote-tracking ref.
  HOME="$home" "$project/bin/skill-q" status --json > "$TEST_ROOT/status-behind.json"
  rg -q '"state": "behind"' "$TEST_ROOT/status-behind.json"
  rg -q '"behind": 1' "$TEST_ROOT/status-behind.json"
  rg -q '"update_available": true' "$TEST_ROOT/status-behind.json"
  HOME="$home" "$project/bin/skill-q" status > "$TEST_ROOT/status-behind.txt"
  rg -q '^  state         behind$' "$TEST_ROOT/status-behind.txt"

  # A stale remote-tracking ref must not be able to hide the update.
  git -C "$project" update-ref -d refs/remotes/origin/master 2>/dev/null || true
  HOME="$home" "$project/bin/skill-q" status --json > "$TEST_ROOT/status-refetch.json"
  rg -q '"state": "behind"' "$TEST_ROOT/status-refetch.json"
}

test_status_json_reports_unreachable_without_a_remote() {
  local project="$TEST_ROOT/unreachable"
  local home="$TEST_ROOT/unreachable-home"
  copy_project "$project"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial
  HOME="$home" "$project/bin/skill-q" install --agents claude >/dev/null

  HOME="$home" "$project/bin/skill-q" status --json > "$TEST_ROOT/status-unreachable.json"
  rg -q '"state": "unreachable"' "$TEST_ROOT/status-unreachable.json"
  rg -q '"state_reason": "no tracked upstream branch"' "$TEST_ROOT/status-unreachable.json"
}

test_update_refuses_dirty_and_diverged_checkouts() {
  local project="$TEST_ROOT/update-safety"
  local remote="$TEST_ROOT/update-safety.git"
  local home="$TEST_ROOT/update-safety-home"
  local author="$TEST_ROOT/update-safety-author"
  make_installed_fixture "$project" "$remote" "$home" claude

  git clone -q "$remote" "$author"
  git -C "$author" config user.email test@example.invalid
  git -C "$author" config user.name 'Test Runner'
  echo upstream > "$author/upstream-file"
  git -C "$author" add upstream-file
  git -C "$author" commit -qm upstream
  git -C "$author" push -q

  local before scratch="$TEST_ROOT/update-safety-scratch"
  mkdir -p "$scratch"
  before=$(readlink "$home/.claude/skills/example-skill")

  # An edit to a tracked file is what a fast-forward could conflict with.
  echo scratch >> "$project/commands-src/example-skill/SKILL.md"
  if HOME="$home" "$project/bin/skill-q" update --yes >/dev/null 2>"$scratch/dirty-error"; then
    return 1
  fi
  rg -q 'refusing to update a dirty checkout' "$scratch/dirty-error"
  [[ ! -e "$project/upstream-file" ]]
  git -C "$project" checkout -q -- commands-src/example-skill/SKILL.md

  # --check reports without touching anything, even when an update exists.
  HOME="$home" "$project/bin/skill-q" update --check > "$scratch/check.txt"
  rg -q 'Update available' "$scratch/check.txt"
  [[ ! -e "$project/upstream-file" ]]

  # Without a terminal there is nobody to ask, so an unconfirmed update fails.
  if HOME="$home" "$project/bin/skill-q" update </dev/null >/dev/null 2>"$scratch/confirm-error"; then
    return 1
  fi
  rg -q 'refusing to update without confirmation' "$scratch/confirm-error"

  git -C "$project" commit -q --allow-empty -m 'local only'
  if HOME="$home" "$project/bin/skill-q" update --yes >/dev/null 2>"$scratch/diverged-error"; then
    return 1
  fi
  rg -q 'refusing to update a diverged checkout' "$scratch/diverged-error"
  [[ ! -e "$project/upstream-file" ]]
  [[ $(readlink "$home/.claude/skills/example-skill") == "$before" ]]
}

test_update_fast_forwards_and_refreshes_everything() {
  local project="$TEST_ROOT/update-apply"
  local remote="$TEST_ROOT/update-apply.git"
  local home="$TEST_ROOT/update-apply-home"
  local author="$TEST_ROOT/update-apply-author"
  make_installed_fixture "$project" "$remote" "$home" claude,opencode

  git clone -q "$remote" "$author"
  git -C "$author" config user.email test@example.invalid
  git -C "$author" config user.name 'Test Runner'
  mkdir -p "$author/commands-src/added-skill"
  cat > "$author/commands-src/added-skill/SKILL.md" <<'EOF'
---
name: added-skill
description: fixture
---

body
EOF
  "$author/bin/build.sh" >/dev/null
  git -C "$author" add -A
  git -C "$author" commit -qm 'add added-skill'
  git -C "$author" push -q

  local state
  state=$(dirname "$(manifest_of "$home")")
  mkdir -p "$state"
  : > "$state/last-check"
  : > "$state/snooze-until"

  HOME="$home" "$project/bin/skill-q" update --yes > "$TEST_ROOT/update-apply.txt" 2>&1
  rg -q 'skills changed    added-skill' "$TEST_ROOT/update-apply.txt"

  [[ -L "$home/.claude/skills/added-skill" ]]
  [[ -L "$home/.config/opencode/commands/added-skill.md" ]]
  [[ -f "$project/commands/added-skill/SKILL.md" ]]
  # The update must leave no throttle or snooze state pretending to be current.
  [[ ! -e "$state/last-check" && ! -e "$state/snooze-until" ]]
  rg -q '"last_update": "2' "$(manifest_of "$home")"
  HOME="$home" "$project/bin/skill-q" doctor --strict >/dev/null
}

test_uninstall_removes_managed_entries_only() {
  local project="$TEST_ROOT/uninstall"
  local home="$TEST_ROOT/uninstall-home"
  copy_project "$project"
  HOME="$home" "$project/bin/skill-q" install --agents claude,codex,opencode >/dev/null

  # A user-owned directory that collides with a managed name, plus an unrelated
  # skill and command that skill-q never touched.
  rm "$home/.claude/skills/funny-text-rewriter"
  mkdir -p "$home/.claude/skills/funny-text-rewriter" "$home/.claude/skills/user-skill"
  echo mine > "$home/.claude/skills/funny-text-rewriter/SKILL.md"
  echo mine > "$home/.claude/skills/user-skill/SKILL.md"
  echo mine > "$home/.config/opencode/commands/user-command.md"

  # Removing one agent keeps the manifest and the other agents intact.
  HOME="$home" "$project/bin/skill-q" uninstall --agents codex --yes >/dev/null
  [[ ! -e "$home/.agents/skills/example-skill" ]]
  [[ ! -e "$home/.codex/skills/example-skill" ]]
  [[ -L "$home/.claude/skills/example-skill" ]]
  rg -q '"agents": \["claude", "opencode"\]' "$(manifest_of "$home")"

  HOME="$home" "$project/bin/skill-q" uninstall --yes > "$project/uninstall.txt"

  [[ ! -e "$home/.claude/skills/example-skill" ]]
  [[ ! -e "$home/.config/opencode/skills/example-skill" ]]
  [[ ! -e "$home/.config/opencode/commands/example-skill.md" ]]
  # Everything the user owns survives, including the colliding name.
  [[ $(cat "$home/.claude/skills/funny-text-rewriter/SKILL.md") == mine ]]
  [[ $(cat "$home/.claude/skills/user-skill/SKILL.md") == mine ]]
  [[ $(cat "$home/.config/opencode/commands/user-command.md") == mine ]]
  rg -q 'preserved .*/.claude/skills/funny-text-rewriter' "$project/uninstall.txt"
  # The checkout stays unless it is explicitly asked for.
  [[ -f "$project/bin/skill-q" ]]
  [[ -z $(manifest_of "$home") ]]
}

test_uninstall_refuses_to_delete_a_dirty_checkout() {
  local project="$TEST_ROOT/uninstall-dirty"
  local home="$TEST_ROOT/uninstall-dirty-home"
  copy_built_project "$project"
  git -C "$project" init -q
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name 'Test Runner'
  git -C "$project" add .
  git -C "$project" commit -qm initial
  HOME="$home" "$project/bin/skill-q" install --agents claude >/dev/null
  echo scratch > "$project/uncommitted"

  # Even an untracked file is enough: deleting the checkout would destroy it.
  if HOME="$home" "$project/bin/skill-q" uninstall --yes --remove-checkout \
      >/dev/null 2>"$TEST_ROOT/uninstall-dirty-error"; then
    return 1
  fi
  rg -q 'refusing to delete a dirty checkout' "$TEST_ROOT/uninstall-dirty-error"
  [[ -d "$project" ]]

  rm "$project/uncommitted"
  HOME="$home" "$project/bin/skill-q" uninstall --yes --remove-checkout >/dev/null
  [[ ! -e "$project" ]]
}

test_update_state_is_namespaced_per_installation() {
  local one="$TEST_ROOT/ns-one"
  local two="$TEST_ROOT/ns-two"
  local remote_one="$TEST_ROOT/ns-one.git"
  local remote_two="$TEST_ROOT/ns-two.git"
  local home="$TEST_ROOT/ns-home"
  local author="$TEST_ROOT/ns-author"
  make_git_fixture "$one" "$remote_one"
  make_git_fixture "$two" "$remote_two"

  advance() {
    local remote=$1 clone=$2
    git clone -q "$remote" "$clone"
    git -C "$clone" config user.email test@example.invalid
    git -C "$clone" config user.name 'Test Runner'
    git -C "$clone" commit -q --allow-empty -m newer
    git -C "$clone" push -q
  }
  advance "$remote_one" "$author-1"
  advance "$remote_two" "$author-2"

  [[ $(HOME="$home" SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$one/bin/update-check") == UPGRADE_AVAILABLE* ]]
  HOME="$home" "$one/bin/snooze.sh" >/dev/null

  # Snoozing one checkout must not silence an unrelated one.
  [[ $(HOME="$home" SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$one/bin/update-check") == UP_TO_DATE ]]
  [[ $(HOME="$home" SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$two/bin/update-check") == UPGRADE_AVAILABLE* ]]

  # The check can be switched off entirely; the CLI stays authoritative.
  [[ -z $(HOME="$home" SKILL_Q_DISABLE_UPDATE_CHECK=1 SKILL_Q_CHECK_INTERVAL_SECONDS=0 "$two/bin/update-check") ]]
}

test_cloud_bootstrap_does_not_copy_through_managed_symlinks() {
  local project="$TEST_ROOT/cloud-symlink"
  local remote="$TEST_ROOT/cloud-symlink.git"
  local home="$TEST_ROOT/cloud-symlink-home"
  make_git_fixture "$project" "$remote"
  local ref
  ref=$(git -C "$project" rev-parse HEAD)

  # An interactive install in the same HOME leaves symlinks pointing back into
  # the checkout; a pinned copy must replace them, never write through them.
  HOME="$home" SKILL_Q_AGENTS=claude,opencode "$project/bin/skill-q" install >/dev/null
  echo 'CHECKOUT-SENTINEL' >> "$project/commands/example-skill/SKILL.md"
  echo 'CHECKOUT-SENTINEL' >> "$project/opencode-commands/example-skill.md"

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null 2>&1

  rg -q 'CHECKOUT-SENTINEL' "$project/commands/example-skill/SKILL.md"
  rg -q 'CHECKOUT-SENTINEL' "$project/opencode-commands/example-skill.md"
  for path in \
    .claude/skills/example-skill \
    .config/opencode/skills/example-skill \
    .config/opencode/commands/example-skill.md; do
    [[ ! -L "$home/$path" ]]
    [[ -e "$home/$path" ]]
  done
  ! rg -q 'CHECKOUT-SENTINEL' "$home/.claude/skills/example-skill/SKILL.md"
  ! rg -q 'CHECKOUT-SENTINEL' "$home/.config/opencode/commands/example-skill.md"
}

test_cloud_bootstrap_v2_removes_pinned_v1_shims() {
  local project="$TEST_ROOT/cloud-v2"
  local remote="$TEST_ROOT/cloud-v2.git"
  local home="$TEST_ROOT/cloud-v2-home"
  local commands="$home/.config/opencode/commands"
  make_git_fixture "$project" "$remote"
  local ref
  ref=$(git -C "$project" rev-parse HEAD)

  HOME="$home" SKILL_Q_OPENCODE_VERSION=v1 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null 2>&1
  [[ -f "$commands/example-skill.md" && ! -L "$commands/example-skill.md" ]]
  echo 'user owned' > "$commands/user-command.md"

  # Rebuilding the image on a reused layer with OpenCode v2 must clear the
  # pinned copies, or every skill shows up twice.
  HOME="$home" SKILL_Q_OPENCODE_VERSION=v2 \
    "$project/bin/cloud-bootstrap.sh" "file://$remote" "$ref" >/dev/null 2>&1

  [[ ! -e "$commands/example-skill.md" ]]
  [[ ! -e "$commands/funny-text-rewriter.md" ]]
  [[ $(cat "$commands/user-command.md") == 'user owned' ]]
  [[ -f "$home/.config/opencode/skills/example-skill/SKILL.md" ]]
}

# An artifact directory is a path this repository owns and replaces wholesale.
# A destination that escapes the checkout would let a mistaken targets.conf edit
# delete unrelated user data, so the build must refuse it before touching disk.
test_build_rejects_an_artifact_destination_outside_the_checkout() {
  local project="$TEST_ROOT/artifact-paths"
  local victim="$TEST_ROOT/artifact-paths-victim"
  copy_project "$project"
  mkdir -p "$victim"
  echo keep > "$victim/sentinel"

  sed -i.bak 's|CANONICAL_DEST="commands"|CANONICAL_DEST="../artifact-paths-victim"|' \
    "$project/bin/targets/targets.conf"
  rm -f "$project/bin/targets/targets.conf.bak"

  if "$project/bin/build.sh" >/dev/null 2>"$project/error"; then
    echo 'build accepted an artifact destination outside the checkout' >&2
    return 1
  fi
  rg -q 'Invalid CANONICAL_DEST' "$project/error"
  [[ $(cat "$victim/sentinel") == keep ]]
}

run_test --fast 'harness terminates a stalled test' test_harness_terminates_a_stalled_test
run_test --fast 'build injects once and copies support files' test_build_injects_header_and_support_files
run_test --fast 'registry publishes self-contained skills without the checkout header' test_build_registry_publishes_self_contained_skills
run_test --fast 'registry check detects content and mode drift' test_build_registry_check_detects_drift
run_test --fast 'invalid registry build preserves published skills' test_build_registry_rejects_invalid_frontmatter_without_destroying_output
run_test --fast 'invalid build preserves previous deployment' test_build_rejects_invalid_frontmatter_without_destroying_output
run_test --fast 'build accepts crlf frontmatter' test_build_accepts_crlf_frontmatter
run_test --fast 'build generates delegating opencode command shims' test_build_generates_opencode_command_shims
run_test --fast 'opencode version detection and override' test_opencode_version_detection
run_test --fast 'sync is idempotent and preserves collisions' test_sync_is_idempotent_and_preserves_collisions
run_test 'sync removes links for deleted skills' test_sync_removes_links_for_deleted_skills
run_test 'sync installs opencode v1 commands without clobbering' test_sync_installs_opencode_v1_commands
run_test 'sync removes stale opencode commands' test_sync_removes_stale_opencode_commands
run_test 'opencode v2 sync removes generated commands' test_sync_v2_removes_generated_commands
run_test --fast 'build outputs are gitignored disposable artifacts' test_build_outputs_are_gitignored_artifacts
run_test --fast 'build rejects an artifact destination outside the checkout' test_build_rejects_an_artifact_destination_outside_the_checkout
run_test 'install from source-only checkout succeeds' test_install_from_source_only_checkout
run_test 'apply update rebuilds after pull' test_apply_update_rebuilds_after_pull
run_test 'cloud bootstrap builds source-only pinned ref' test_cloud_bootstrap_uses_source_only_ref
run_test 'update check reports current, upgrade, and snooze states' test_update_check_states
run_test 'update check fails open without a remote' test_update_check_fails_open_without_remote
run_test 'apply update fast-forwards and resynchronizes' test_apply_update_fast_forwards_and_resyncs
run_test 'cloud bootstrap installs copies from a pinned ref' test_cloud_bootstrap_copies_pinned_content
run_test 'cloud bootstrap installs pinned command shims' test_cloud_bootstrap_installs_command_shims
run_test 'new canonical consumer from targets.conf is synced locally' test_sync_new_canonical_consumer_from_targets_conf
run_test 'cloud v2 bootstrap removes managed shims preserves user files' test_cloud_v2_bootstrap_removes_managed_shims_preserves_user_files

run_test 'init installs only the selected agents' test_init_installs_only_selected_agents
run_test 'install is idempotent and records a manifest' test_install_is_idempotent_and_records_a_manifest
run_test 'install repairs a moved checkout' test_install_repairs_a_moved_checkout
run_test 'sync drops deselected agents' test_sync_drops_deselected_agents
run_test 'status reports behind with stable json' test_status_reports_behind_and_stable_json
run_test 'status reports unreachable without an upstream' test_status_json_reports_unreachable_without_a_remote
run_test 'update refuses dirty and diverged checkouts' test_update_refuses_dirty_and_diverged_checkouts
run_test 'update fast-forwards and refreshes everything' test_update_fast_forwards_and_refreshes_everything
run_test 'uninstall removes managed entries only' test_uninstall_removes_managed_entries_only
run_test 'uninstall refuses to delete a dirty checkout' test_uninstall_refuses_to_delete_a_dirty_checkout
run_test 'update state is namespaced per installation' test_update_state_is_namespaced_per_installation
run_test 'cloud bootstrap never copies through managed symlinks' test_cloud_bootstrap_does_not_copy_through_managed_symlinks
run_test 'cloud bootstrap v2 removes pinned v1 shims' test_cloud_bootstrap_v2_removes_pinned_v1_shims

skill_q_test_finish 'integration'
