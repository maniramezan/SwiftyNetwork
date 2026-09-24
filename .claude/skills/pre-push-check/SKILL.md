---
name: pre-push-check
description: Run SwiftyNetwork's local quality gates (format lint, build, tests, DocC curation, docs consistency) before committing or pushing, with a fallback when no Swift toolchain is available. Use before every commit/push and before opening a PR.
---

# Pre-push checks

Run from the repository root. Stop at the first failure and fix it.

```bash
swift format lint --strict -r -p Sources Tests   # CI uses the same strict mode
swift build
swift build -c release                            # CI builds release
swift test                                        # or --filter <Suite> while iterating
git diff --check
```

## Also verify by reading the diff

- [ ] No line over 120 characters (`awk 'length > 120' $(git ls-files '*.swift')`).
- [ ] New public top-level types are curated in `SwiftyNetwork.docc/SwiftyNetwork.md`.
- [ ] Every ``` ``Symbol`` ``` DocC link in changed comments names a real public symbol
      (Docs CI uses `--warnings-as-errors`).
- [ ] README / AGENTS.md / ARCHITECTURE.md updated if public behavior or file layout changed.
- [ ] REVIEW.md: move findings you resolved out of "Priority follow-ups"; add new
      findings you discovered but did not fix.
- [ ] No secrets, tokens, or production URLs; no changelog files.
- [ ] Commit message: imperative, optional scope prefix (`network:`, `cache:`, `docs:` ...).

## No Swift toolchain?

Cloud sandboxes may block toolchain downloads. Then:

1. Still run `git diff --check` and the 120-column check above.
2. Re-read every changed Swift file for: Sendable violations, missing `await`/`try`,
   mutating calls inside `#expect`, unresolved names from moved types.
3. Push to the PR branch and treat the GitHub Actions `Build` (format → build → test)
   and `Docs` workflows as the compiler. Read failing job logs and fix before
   reporting success. Say explicitly that local verification was not possible.
