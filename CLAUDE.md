# SwiftyNetwork - Claude Guidelines

> Claude-specific extensions to [AGENTS.md](AGENTS.md).
> AGENTS.md is the source of truth for all conventions, commands, and patterns.
> This file only contains what Claude Code needs beyond that.

## Co-Author Tag

```
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Skills

Load these when their domain applies:

| Skill | When to Load |
|---|---|
| `swift-concurrency` | Modifying actors, async functions, or Sendable types |
| `swift-testing-expert` | Writing or reviewing tests |
| `swift-concurrency-pro` | Reviewing concurrency correctness |
| `swift-testing-pro` | Reviewing test quality |

## Session Start

1. Verify `.claude/settings.local.json` is in `.gitignore`
2. `swift build` -- confirm clean compilation
3. `swift test` -- confirm passing before and after changes
4. `swift format lint --strict -r -p Sources Tests` -- confirm before committing
