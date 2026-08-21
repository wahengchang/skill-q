# Skill Authoring Instructions

These instructions apply to every `SKILL.md` under `commands-src/`.

Write skills as compact executable workflow specifications, not essays. The agent should be able to read the skill and know what to do, when to branch, when to stop, and what result to return without inventing a second workflow.

## Core style

- Keep one skill focused on one job. Follow the repository quick rule: prefer under 100 lines.
- Prefer short natural-language control flow over prose explanation or shell-like orchestration.
- Use numbered steps for the main workflow. Each step should cause an action, decision, verification, or stop.
- Put conditions next to the action they control: `If ...`, `Otherwise ...`, `Only when ...`, `Do not ...`, `Stop if ...`.
- Use imperative language. Say what the agent must do, not what it should merely consider.
- Make important boundaries explicit with `must`, `only`, `never`, or `do not` when the distinction matters.
- Keep reasoning in natural language; use commands or scripts for deterministic operations.
- The agent controls tools; tools do not control the agent.
- Do not encode the workflow as a large Bash/Python program inside `SKILL.md` when a short instruction is clearer.
- Ask the user only when a missing choice can materially change scope, behavior, or output. Resolve non-critical details from repository conventions.

## Progressive disclosure

Keep the main `SKILL.md` sufficient to run the common path without loading it with every possible detail.

- Put reusable domain detail in `references/` only when it clearly shortens or stabilizes the main workflow.
- Put deterministic or repetitive operations in `scripts/` only when they reduce ambiguity or repeated command generation.
- Keep rare edge cases close to the step that needs them.
- Do not duplicate repository-wide build, naming, or contribution rules already defined by `CONTRIBUTING.md`.

## Preferred shape

Every skill starts with:

```markdown
---
name: y-<name>
description: <what the skill does and when it should trigger>
---
```

Then prefer:

1. `# <skill-name>` when a title improves scanning.
2. One sentence stating the job of the skill.
3. `## Instructions` containing the executable workflow.
4. Optional narrow sections such as `## Output`, `## Boundaries`, or `## Verification` only when needed.
5. `## Provenance` only for source maintenance history.

Do not add sections merely to make the file look complete.

## Workflow writing

For `## Instructions`:

1. Start with the minimum context or validation needed before acting.
2. Describe the normal path first.
3. Express meaningful branches explicitly in place.
4. State destructive, irreversible, or externally visible actions before they happen when confirmation is required.
5. Verify success when it cannot be inferred from the action itself.
6. End at the expected result or stop condition. Do not drift into unrelated follow-up work.

Prefer:

```markdown
1. Read the target file and identify the current behavior.
2. If the requested scope is ambiguous in a way that changes behavior, ask one focused question and stop.
3. Make the smallest change that satisfies the request.
4. Run the relevant verification.
5. If verification fails, report the failure and do not claim success.
```

Avoid vague instructions such as "think carefully", "inspect anything relevant", or "continue until everything looks good" when the actual workflow can be stated directly.

## Tool and script boundary

Use natural language for judgment and routing; use tools for deterministic work.

```text
Agent: understand -> decide -> route -> verify
Tool/script: read -> search -> transform -> test -> write
```

Commands support the workflow rather than replace it. When a deterministic operation becomes long, repeated, or fragile, move it into a local script and let `SKILL.md` say when and why to run it.

## Authoring check

Before finishing a new or edited skill, verify:

- Folder name and frontmatter `name` match and use the `y-` prefix.
- `description` contains both capability and trigger.
- The skill has one clear job and one obvious normal path.
- Important branches and stop conditions are explicit.
- Confirmation boundaries are explicit when needed.
- The text tells the agent what to do instead of explaining the topic at length.
- Deterministic work is delegated to commands/scripts when clearer.
- Optional references/scripts exist only when they make execution shorter or more reliable.
- The common path can be understood without unrelated repository documents.
- The skill remains quick, compact, and directly executable.
