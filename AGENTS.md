# Codex Development Instructions

- skill-q ships quick, lightweight skills. Every skill in `commands-src/` is named with the `q-` prefix (`q-<name>`), and the folder name must match frontmatter `name:`. Keep each `SKILL.md` focused, low-ceremony, and directly executable.
- `commands-src/` and `_shared/` are the only tracked skill build inputs. Skill content lives in `commands-src/<name>/SKILL.md`; `_shared/update-check-header.md` is inserted into every generated skill.
- Generated `commands/` and `opencode-commands/` remain disposable legacy build outputs declared in `.gitignore`. The tracked `skills/` tree is the public `npx skills` distribution: never hand-edit it, but do commit the result of `bin/build-registry.sh`.
- After changing a skill, run `bin/build-registry.sh` and `bin/build.sh`, then `make test` (the fast subset). Changes under `bin/`, `tests/`, or `bin/targets/` require `make test-full`.
- A `## Provenance` section in a canonical source is maintenance history: `bin/build.sh` strips it from generated artifacts, so keep it in `commands-src/` only.
- Use `bin/skill-q sync` (or compatibility wrapper `bin/sync-skills.sh`) when you want to refresh local agent links.
- Follow `CONTRIBUTING.md` and `ARCHITECTURE.md`; keep framework changes generic and do not hard-code one personal skill set.

## Adding an AI runtime

The build pipeline separates canonical processing from target metadata (`bin/targets/targets.conf`) and transform adapters (`bin/targets/<adapter>.sh`).

- **Canonical-format target:** append `<consumer>:<skill-directory>` to `CANONICAL_CONSUMERS`; no transform script is needed.
- **Transformed target:** add `bin/targets/<adapter>.sh` and register `<adapter>:<artifact-directory>` in `TRANSFORMED_TARGETS`.

Adapter contract:

- `<adapter>.sh build <canonical-staging-dir> <artifact-staging-dir>`
- `<adapter>.sh sync <artifact-dir>`
- `<adapter>.sh bootstrap <artifact-dir>`

`build` receives the fully processed canonical staging tree after header injection and support-file materialization.
