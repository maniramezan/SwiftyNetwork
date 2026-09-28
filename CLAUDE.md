# SwiftyNetwork - Claude Guidelines

> Claude-specific extensions to [AGENTS.md](AGENTS.md).
> AGENTS.md is the source of truth for all conventions, commands, and patterns.
> This file only contains what Claude Code needs beyond that.

## Co-Author Tag

```
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Skills

Repo skills live in [.claude/skills/](.claude/skills); Claude Code discovers them automatically:

| Skill | When to Load |
|---|---|
| `add-component` | Adding a new public type, file, or library product |
| `write-tests` | Writing or reviewing tests; choosing between TestURLProtocol, MockAPIClient, FakeAPIClient |
| `concurrency-review` | Modifying actors, `Task {}`, `AsyncStream`, cache/mutation ordering |
| `pre-push-check` | Before every commit/push (includes the no-toolchain fallback) |

If your environment also provides the general `swift-concurrency`, `swift-concurrency-pro`,
`swift-testing-expert`, or `swift-testing-pro` skills, use them alongside the repo skills; the repo
skills win where they conflict.

## Session Start

1. Verify `.claude/settings.local.json` is in `.gitignore`
2. `swift build` -- confirm clean compilation (if `swift` is unavailable, follow the
   no-toolchain section of `pre-push-check` and say so in your summary)
3. `swift test` -- confirm passing before and after changes
4. `swift format lint --strict -r -p Sources Tests` -- confirm before committing
