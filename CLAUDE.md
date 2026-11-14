# Working rules for Mythwatch

Mythwatch is a native Apple TV client for MythTV. Before changing anything, read `docs/SPEC.md`
and the task you were given in `docs/TASKS.md`. For backend work also read `docs/BACKEND-V35.md`.

**If you are the orchestrating session** (started by the owner in this directory, not a subagent
given one task): read `docs/ORCHESTRATION.md` first. It holds the project status and how to run tasks.

## Rules

1. **Test first.** Write the tests listed for the task, run them and see them fail, then
   implement. Do not weaken or delete a test to make it pass; if a listed test is wrong, say so
   in your report and fix the spec in the same commit.
2. **Respect the dependency rule** in SPEC §2. Never add a dependency between package targets
   that the table does not allow. Only `MythBackendV35` may contain v35 endpoint paths or JSON keys.
3. **No real I/O in package tests.** No network, no real clock, no `Task.sleep`, no file access
   outside bundled fixtures. Inject fakes from `MythwatchTestSupport`.
4. **The live backend is someone's working DVR.** GET requests are fine. Never send a POST
   (watched, position, bookmark, delete) to a live backend unless the task says the owner has
   nominated a recording, and then only for that recording.
5. **Spec changes travel with code.** If an interface in the spec has to change, change the spec
   in the same commit and call it out in your report.
6. **Stay inside the task.** Do not start later tasks, add features, or refactor neighbours.
7. Swift 6 language mode, strict concurrency, no `@unchecked Sendable` and no
   `nonisolated(unsafe)` without a comment explaining why it is safe.
8. User-facing text is plain English, built in one place (`UserMessage`), never a raw error.

## Commands

```
cd MythwatchKit && swift test                      # all package tests; must stay under 10 s
cd MythwatchKit && swift test --filter <Name>      # one suite or test
MYTHWATCH_LIVE_BACKEND=http://host:6544 swift test --filter Live    # read-only live tests
xcodebuild -project Mythwatch/Mythwatch.xcodeproj -scheme Mythwatch \
  -destination 'platform=tvOS Simulator,name=Apple TV' test          # app build + UI tests
```

## Reference material

- MythTV v35 source: `../mythtv` (branch `fixes/35`). Read-only. Do not copy code from it; it is GPL.
- The owner's other tvOS project, for project-file and layout conventions: `../cable-82-tv`.

## Task report

End every task with: what was built, the tests added (count and names of suites), the output of
the final `swift test` run, any spec changes, any `[verify]` items settled or newly found, and
anything you could not check.
