#!/usr/bin/env bash
set -euo pipefail

# Builds the tracked `skills/` tree consumed by `npx skills add`.
#
# This is deliberately NOT `bin/build.sh` with another target adapter. The
# legacy pipeline injects `_shared/update-check-header.md`, which tells the
# agent to walk up from SKILL.md to a skill-q checkout and run
# `bin/update-check`. A skill installed by `npx skills` lives in
# `.claude/skills/<name>/` with no repository above it, so that header only
# ever reaches its own "repository not found -> just run the skill" branch.
# Published skills therefore omit it, and npx users update by re-running
# `npx skills add wahengchang/skill-q` (see README).

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/commands-src"
DEST="$ROOT/skills"
MODE="build"

case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  *)
    echo "Usage: bin/build-registry.sh [--check]" >&2
    exit 2
    ;;
esac

[[ -d "$SRC" ]] || { echo "Missing source directory: $SRC" >&2; exit 1; }
[[ ! -L "$DEST" ]] || { echo "Refusing symlink destination: $DEST" >&2; exit 1; }

# `diff -r` compares content only, so an executable support script that lost
# its bit would read as in sync. Compare the executable bit separately.
exec_manifest() {
  local root=$1 file
  ( cd -- "$root" && find . -type f -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        if [[ -x "$file" ]]; then printf '%s\tx\n' "$file"; else printf '%s\t-\n' "$file"; fi
      done )
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/skills-registry.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
staged="$tmp/skills"
mkdir -p "$staged"

found=0
while IFS= read -r -d '' source_file; do
  found=1
  skill_dir=$(dirname "$source_file")
  folder_name=$(basename "$skill_dir")
  output_dir="$staged/$folder_name"
  output_file="$output_dir/SKILL.md"
  relative_source=${source_file#"$ROOT/"}

  # Both delimiters are required, and the opening one must be line 1. Checking
  # it here keeps the error honest: without it a body-only file reports itself
  # as a name mismatch against an empty name.
  first_line=$(head -n 1 "$source_file" | tr -d '\r')
  frontmatter_end=$(awk 'NR > 1 && /^---[[:space:]]*$/ { print NR; exit }' "$source_file")
  [[ "$first_line" == "---" && -n "$frontmatter_end" ]] || {
    echo "Invalid frontmatter in ${relative_source}: expected opening and closing ---" >&2
    exit 1
  }

  declared_name=$(sed -n "2,${frontmatter_end}p" "$source_file" |
    sed -n 's/^name:[[:space:]]*//p' | head -n 1)
  description=$(sed -n "2,${frontmatter_end}p" "$source_file" |
    sed -n 's/^description:[[:space:]]*//p' | head -n 1)

  [[ "$declared_name" == "$folder_name" ]] || {
    echo "Skill name mismatch: folder=$folder_name frontmatter=$declared_name" >&2
    exit 1
  }
  [[ -n "$description" ]] || {
    echo "Missing description: ${relative_source}" >&2
    exit 1
  }

  mkdir -p "$output_dir"
  # `## Provenance` is maintenance history for this repository, not instruction
  # for the agent loading the published skill. Skipping runs to the next H2 so
  # the section is not required to be last. Kept in step with the equivalent
  # rules in bin/build.sh.
  awk '
    { sub(/\r$/, "") }
    /^## Provenance[ \t]*$/ { skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    skipping { next }
    { print }
  ' "$source_file" > "$output_file"

  # Follow shared support-file symlinks so each published skill stays
  # self-contained: `npx skills add --skill <name>` installs one directory.
  while IFS= read -r -d '' support_file; do
    relative=${support_file#"$skill_dir/"}
    mkdir -p "$output_dir/$(dirname "$relative")"
    cp -aL "$support_file" "$output_dir/$relative"
  done < <(find -L "$skill_dir" -type f ! -name SKILL.md -print0)
done < <(find "$SRC" -mindepth 2 -maxdepth 2 -type f -name SKILL.md -print0 | sort -z)

(( found )) || { echo "No skills found in $SRC" >&2; exit 1; }

if [[ "$MODE" == "check" ]]; then
  [[ -d "$DEST" ]] || {
    echo "Missing published skills/. Run bin/build-registry.sh." >&2
    exit 1
  }
  stale=0
  if ! diff -qr "$DEST" "$staged" >/dev/null; then
    echo "Published skills/ is stale. Run bin/build-registry.sh and commit the result." >&2
    diff -ruN "$DEST" "$staged" || true
    stale=1
  fi
  if ! mode_drift=$(diff <(exec_manifest "$DEST") <(exec_manifest "$staged")); then
    echo "Published skills/ has file-mode drift. Run bin/build-registry.sh and commit the result." >&2
    printf '%s\n' "$mode_drift" >&2
    stale=1
  fi
  (( stale == 0 )) || exit 1
  echo "Published skills/ matches commands-src/."
  exit 0
fi

# One directory swap, so a consumer never observes a half-built tree.
rm -rf "$DEST"
mv "$staged" "$DEST"
echo "Built npx-skills distribution in $DEST"
