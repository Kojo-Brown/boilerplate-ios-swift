# boilerplate-ios-swift — Agent Instructions

## What this repo is
Production-grade Swift 6 + SwiftUI iOS boilerplate. Spec-driven and PR-driven: one `SPEC.md` item per run.

## Your job (scheduled agent, every 4h)
1. `git checkout main && git pull --ff-only origin main`
2. Read `SPEC.md`, take the **first** `- [ ]` item. Phase 0 items always win.
3. `git checkout -b <type>/<kebab-slug>` (`feat`/`fix`/`chore`/`ci`/`docs`)
4. Implement it completely — source, types, tests, docs.
5. Run every gate locally; **all must pass** before pushing:
   ```
   swift --version
   xcodebuild -scheme App -destination 'generic/platform=iOS' build-for-testing
   swiftlint --strict
   xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'
   xcodebuild -scheme App build
   ```
6. Commit, `git push -u origin <branch>`, then `gh pr create`.
7. `gh pr checks --watch` → **merge only if every check is green**:
   `gh pr merge --squash --delete-branch`
8. Pull main, mark the item `- [x]` in `SPEC.md`, update
   `../PROGRESS.md`, push as a `chore:` commit.

If a check fails, fix forward on the same branch. Never merge red. Never
weaken a test or lower a threshold to force green — if a gate is genuinely
wrong, change it deliberately and say why in the PR.

## Secrets
Never commit real credentials, tokens, keys, or `.env` files. Placeholders in
`.env.example` only; CI reads from the GitHub secret store. Test fixtures must
look obviously fake. Scan `git diff --cached` before every push.

## Conventions
- Strict concurrency on; everything crossing an isolation boundary is `Sendable`
- `@Observable` view models, `@MainActor` isolated
- Protocol-based repositories so previews and tests inject fakes
- Tokens in Keychain with access-control flags, never `UserDefaults`
- Value types by default; reach for a class only when identity matters

See `../ROUTINE.md` for the full workflow.
