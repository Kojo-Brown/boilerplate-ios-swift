# A TDD kata: one use-case, red → green → refactor, one commit per step

Phase 12 item 2. The use-case is **renaming the signed-in user's profile**, and
it was built test-first in four cycles, each cycle two commits, with the
refactor and the wiring after them. The ten commits are the artefact — the code
they produce is ordinary, and a reader who only looks at the final diff learns
the one thing a kata is not for.

This page is what the history cannot say for itself: why each test was the next
one to write, what its failure proved, and — at the end — which of those claims
this repository can actually stand behind and which it can only predict.

## Why this use-case

A kata needs a subject where the rules arrive one at a time, where each one is
small enough to see, and where the work is real. Renaming a profile qualifies
on all three, and it had a defect in it:

`ProfileFeature.State.canSave` read `!candidate.isEmpty && candidate != user.name`.
That is a rule about names, living in the property that decides whether the Save
button is enabled. It is incomplete — nothing about length — and it is in the
wrong place, because the effect that performs the write,
`ProfileEffectHandler.perform(.saveName(_:))`, is a method, and a button's
enablement is not something a method consults. So the app had a name rule that
the one path it was meant to govern could not see.

The subject was therefore not "add validation". It was: decide where the rule
lives, and let the tests pull it out.

## The ten commits

| # | Commit | Step | What it establishes |
|---|---|---|---|
| 1 | `b429605` | red 1 | A name handed to the use-case ends up on the server. Fails as a *build* failure — no such type. |
| 2 | `56d60ca` | green 1 | `RenameProfileUseCase` holds a `SyncStrategy` and forwards. No rules yet. |
| 3 | `6bb1a95` | red 2 | Surrounding whitespace must not reach the server. Fails on an assertion: `["  Ada Lovelace"]`. |
| 4 | `7d3ed48` | green 2 | `trimmingCharacters(in: .whitespacesAndNewlines)`. |
| 5 | `fea3922` | red 3 | A blank name is refused *and* no request is made. Fails on both assertions. |
| 6 | `d81296c` | green 3 | `ProfileNameError.empty`, with the four-place localisation contract behind it. |
| 7 | `f0320c6` | red 4 | A ceiling, asserted on both sides, counted in characters. |
| 8 | `4bcfb2f` | green 4 | `name.count <= 50`, and the error carries the limit. |
| 9 | `b70e4eb` | refactor | The three rules become `ProfileName`, a `Core` value type. The kata suite is not in the diff. |
| 10 | `420c48e` | wiring | `canSave` and the save effect both ask it. The restated rule is gone. |

Commit 9 is the one to read if you read one. The commits before it are
mechanical by design; it is the only one where something is *decided*.

## What each cycle was actually for

**Cycle 1 — the thing itself.** Before any rule, pin what the use-case is for:
hand it a name, and the profile carries that name. Its red is a build failure,
`cannot find 'RenameProfileUseCase' in scope`, which is what the first red in a
compiled language looks like and is also the weakest kind of red available. It
proves a symbol is missing. It does not prove the assertion can tell two
behaviours apart — a test asserting `1 == 2` against a missing type fails
identically. Every later cycle here is red on an assertion for that reason, and
a kata that stops at compile-failure reds has not shown the part that matters.

**Cycle 2 — trimming.** The name comes from a `TextField`, so a trailing space
is not a caller's mistake: it is what a thumb produces and what iOS
autocorrection inserts after a completed word. Stored, it makes every later
comparison against the name the reader believes they chose false, and renders as
a gap nobody can see in order to delete.

Internal whitespace is left alone, deliberately. Collapsing runs would make the
value sent differ from the value the field shows.

**Cycle 3 — a name that is not a name.** This is the cycle that justifies the
second assertion in the pair. "An error was thrown" alone would pass a use-case
that wrote the blank name and *then* complained about it, which is worse than
either behaviour on its own. `MockSyncStrategy.updateCount` is the assertion
that nothing was sent; `requestedNames` cannot do that job, because an empty
list is also what a refusal looks like one cycle later.

The red asserts `(any Error).self` rather than a case. Naming a case would mean
declaring the error type in the red commit — code before the test that asks for
it, which is the thing the kata exists to show the alternative to.

**Cycle 4 — the ceiling, and a test that was green when it was written.** Two
cases for one rule. The first asserts both sides of the boundary, because an
off-by-one *is* the defect for a limit: `<` instead of `<=` refuses a name that
satisfies the sentence the error message states, and no test that only tries 51
characters can tell.

The second case asserts that twenty family emoji (`👩‍👩‍👧‍👦`) are accepted, and it
passes the moment it is written, with no ceiling in the code at all. It is in
the red commit anyway, because its job is to fail on the *wrong* green rather
than on the missing one. "At most 50 characters" has three spellings in Swift —
`count`, `unicodeScalars.count`, `utf16.count` — and those twenty names are 20,
140 and 220 respectively. Only the first is the rule a reader would recognise.
Writing that case after the implementation would have meant writing it against
whichever spelling had already been chosen.

**The refactor.** Four cycles left `rename(to:)` holding three `guard`s and one
line of work. The `guard`s were never about the write: they answer "what may be
a name", a question `canSave` answers too, and differently. The extraction is
`ProfileName` — a `Core` value type whose existence means "checked", so that
nothing downstream re-checks and nothing restates.

A value type rather than a `validate(_:) throws -> Void` free function, because
the result is worth carrying: normalisation becomes part of identity (`" Ada "`
and `"Ada"` are the same value), which a function returning nothing cannot
express, and a checked string stays distinguishable from an unchecked one one
line later.

What `ProfileName` deliberately does not decide: whether the name is a *change*.
That compares two values and needs the loaded profile. `canSave` keeps it.

The test for the refactor is a diff: `RenameProfileUseCaseTests.swift` does not
appear in commit 9. That is the whole claim of a refactor step, and it is
checkable rather than asserted. What commit 9 does add is
`ProfileNameTests` — the rules now have an address, so they get direct tests
there — and two rows in the Sendable audit.

**The wiring, which is not part of the loop.** A kata that ends at the refactor
leaves a type nothing calls, and a rule nothing applies is a claim. Commit 10
points both call sites at it and deletes the restatement. That is also the
commit where the original defect dies: Save stops being offered for a
51-character name, and the write refuses one even when no button was consulted.

## Two suites, two jobs

`RenameProfileUseCaseTests` asserts the *boundary*: refused, and nothing left
for the server. It is indifferent to which rule broke.

`ProfileNameTests` asserts the *rules*: which error, and that the limit survives
into the sentence the reader sees — a key and value that disagree about `%lld`
render the number away, and nothing else in the suite would notice.

Neither asserts the English prose. It is a translation; a test that pins it
makes the catalog harder to edit without making the app more correct.

## What this kata cannot claim

**Nobody watched these tests fail.** The scheduled agent that wrote these
commits runs on Linux, where `swift`, `xcodebuild` and `swiftlint` do not exist
and Xcode cannot be installed — the same limitation `.github/workflows/ci.yml`
records at the top of the file. CI is the only runner this repository has, and
it builds the *head* of a pull request, not each commit on it. So the failure
messages described above are what each red was written to produce, derived from
the code at that commit. They were reasoned, not observed.

That is a real gap in a kata, of all things, and it is recorded rather than
papered over. What it leaves standing:

* Every commit is a working tree, so the claims are reproducible by anyone with
  a Mac: `git checkout <sha>` at any row of the table above and run
  `xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'`.
  The red rows are predictions that a single command falsifies, which is a
  better position than a kata whose intermediate states were never committed.
* The twelve audits in the lint job are syntactic and *were* run at each commit
  on the agent's box — localisation, module boundaries, test framework, the
  Sendable opt-outs, and the eight security and release checks.
* The head of the branch was green in CI before the merge: build with no
  warnings, SwiftLint strict, and the full simulator run including both new
  suites.

**The commit sequence survives only on the pull request.** This repository
squash-merges, so `main` carries these ten commits as one. The table above is
the index into the PR, which is where the steps can still be read apart.

**One cycle is missing on purpose.** There is no cycle for "the name is
unchanged", because that rule is not about a name — it compares the draft with
the loaded profile, and it already lives in `canSave`, where the profile is.
A kata is a demonstration, and padding it with a fifth cycle in the wrong layer
would demonstrate the wrong thing.

## If you are using this as a kata

Delete `Sources/Networking/UseCases/RenameProfileUseCase.swift`,
`Sources/Core/Models/ProfileName.swift`, `ProfileNameError.swift`, both test
files, and the two call sites in `Sources/Features/Settings/Profile/`. Then
start at commit 1 and do not read ahead. The interesting decisions are in
commit 9, and they are only interesting if the three `guard`s have piled up in
front of you first.
