---
name: orchestrate
description: Decompose a complex multi-step goal into ordered sub-tasks, execute each with the right tool or sub-skill, merge results. Use when the user's request needs multiple distinct phases or apps (e.g., "research X then put it in a deck", "summarize my unread mail and add follow-ups to Things").
emoji: square.grid.3x3
os: macOS
requirements: tool catalog access
---

# Orchestrate

Use when the request can't be answered by a single tool or skill. Treat each phase as a discrete step with its own success criteria, instead of trying to do everything in one LLM turn.

## Workflow

1. **Plan first, act second.** Write down the phases as a numbered list before calling any tools. Phases should be 3–7 in count — fewer means you should just do it directly, more means you should split into two orchestrate runs.
2. **Identify dependencies.** Mark which phases need outputs from earlier phases (sequential) and which can run in any order (parallelizable). Run independent phases concurrently when the underlying tool supports it.
3. **Pick the smallest tool per phase.** Don't reach for `run_shell_command` if `read_file` does it. Don't reach for `run_applescript` if `open_url` does it. The narrower tool is faster, safer, and the user can audit it.
4. **Execute and checkpoint.** After each phase, summarize what you produced in 1–2 lines. This gives the user a chance to interrupt if you've drifted.
5. **Merge.** Compose a final response that ties the phase outputs together with a verdict, not just a concatenation.

## Plan template

```
Goal: <restate user's ask>

Phases:
1. [tool/skill] — <what it produces>
2. [tool/skill] — <what it produces, depends on #1>
3. [tool/skill] — <what it produces, parallel with #2>
4. Synthesize → final response

Estimated calls: <N>
```

State this back to the user before the first tool call when N ≥ 4. They can redirect cheaply now; they can't after $0.50 of LLM spend.

## Composing skills

The most common pattern is `orchestrate` invoking other skills as phases:

- "Research the latest in zero-knowledge proofs and put it in a deck" -> `deep-research` -> `pptx`
- "Summarize my unread mail, add follow-ups to Things, then archive" → `apple-mail` → `things-mac` → `apple-mail` (archive)
- "Find me a slot, schedule the meeting, send the invite" → `apple-calendar` → `apple-mail`

When chaining, pass the structured output (not the human-readable summary) between phases.

## When NOT to use

- Single-tool requests ("what's the weather", "open Safari") — direct tool call is faster.
- Open-ended exploration ("what should I work on today") — the user wants conversation, not a plan.
- Anything destructive without explicit confirmation. Orchestrate is not a license to chain `run_shell_command rm -rf` with `run_applescript empty trash`.

## Gotchas

- **Parallel phases** can race on the same resource. Two phases writing to the same file in parallel will lose data — serialize file writes even if you parallelize reads.
- **Long chains drift**. If a phase produces the wrong output, every downstream phase amplifies the error. Stop and re-plan rather than push through.
- **Cost ceiling**: deep orchestration runs against the per-task LLM cost budget. Prefer one well-planned call over many speculative ones.
