# Orchestration handoff

Written 2026-11-14 by the planning session (Fable), which ran from the MythTV checkout at
`../mythtv`. That session's memory does not carry over to sessions started in this directory, so
this note is the full handoff. Update the "Status" section as work proceeds.

## Status

- Spec complete: `docs/SPEC.md`, `docs/BACKEND-V35.md`, `docs/TASKS.md`, `CLAUDE.md`.
- **M0-1 done and committed** (2026-11-14): git repo on `main`, `MythwatchKit` package skeleton,
  `Tools/check-deps.sh`.
- **M0-2 done and committed** (2026-11-14): `Mythwatch/Mythwatch.xcodeproj`, placeholder app,
  one UI launch test. Next task: **M0-3**, which needs the owner and a real Apple TV; do not
  launch it unattended. Milestone 1 can proceed alongside it.
- **M1-1 done and committed** (2026-11-14): domain types, ports, `BackendError`. Next: **M1-2**,
  then M1-3 and M1-4.
- The owner will run **M0-3** in a direct Opus session (agreed 2026-11-14).
- **iPhone app wanted later** (owner, 2026-11-14). Not scheduled. SPEC §11 holds the rules that
  apply now: the package declares iOS 26 and must stay platform-neutral, view models must not
  assume the remote, and M0-3 must pick a VLCKit build that also covers iOS. When reviewing a
  task that adds a framework import to the package, run the iOS build check in SPEC §11.
- Confirmed by the owner 2026-11-14: bundle-id prefix `com.daleemartin` (the "e" is a middle
  initial); the `NSLocalNetworkUsageDescription` wording in `Mythwatch/Info.plist`.
- Nothing has been pushed anywhere. No GitHub repo exists; create one only when the owner asks.
## Roles the owner chose

- **Fable orchestrates and reviews; it does not write application code.** Implementation is done
  by Sonnet and Opus subagents (the Agent tool's `model` parameter), per the model suggestion on
  each task in `TASKS.md`. Writing or editing the spec documents is the orchestrator's job.
- The owner explicitly asked for subagents here, so spawning them is authorised for this project.
- Tasks that need the owner in the loop are better run by the owner in a direct Opus session
  than as background subagents: **M0-3** (VLCKit spike, needs a real Apple TV), **M3-3**, **M3-4**
  (engine and player screen), **M3-5**, **M5-1** (live writes and delete), and the UI tasks
  **M2-7**, **M4-3**. Offer that choice when each comes up; do not launch them unattended.

## How to run a task

1. Give the subagent one task id. Tell it to read `CLAUDE.md`, `docs/SPEC.md`, its task in
   `docs/TASKS.md`, and `docs/BACKEND-V35.md` for backend work. Subagents start cold; the
   documents are written for that.
2. Run tasks marked ∥ in parallel once their dependencies are done. Milestone 1 does not depend
   on the M0-3 spike and can proceed alongside it. Parallel agents editing the same package
   should use worktree isolation or be given disjoint files.
3. When a task reports back, review before starting anything that depends on it:
   - run `cd MythwatchKit && swift test` yourself; do not trust the reported output alone;
   - check the listed tests exist and test what the task names, not something weaker;
   - run `Tools/check-deps.sh` for the dependency rule (SPEC §2; the debug build only warns),
     and check that no v35 path or JSON key leaked outside `MythBackendV35`;
   - check any spec change the agent made is justified and consistent with the other documents.
4. Commit after each accepted task (the owner approved "one commit per task" as the working
   rule in `CLAUDE.md`). Do not push.
5. At the end of each milestone, give the owner a short status: what is done, what was verified,
   what is still marked `[verify]`.

## The backend

- The owner's MythTV backend is host `basement`, `http://basement:6544`, version **v35.0**.
  It is a working DVR.
- GET requests are fine. **No POST of any kind** unless the owner has nominated a recording for
  that specific check. No POST has ever been sent from this project; every write call in
  `BACKEND-V35.md` is from reading source and unverified.
- MythTV source reference: `../mythtv`, branch `fixes/35`. Read-only, GPL: never copy code from it.
  Do not switch its branch to `master`; master's DB schema (1385) is newer than basement's (1384).
- The owner's other tvOS project `../cable-82-tv` is the model for project layout and the
  hand-written `.xcodeproj` (no project generator is installed on this machine).
- Tooling seen on this machine: Xcode 27.2, Swift 6.4.2, tvOS simulators 26.5 / 27.0 / 27.2.

## Decisions made by the owner (do not reopen)

Name Mythwatch; separate repo; Swift 6 + SwiftUI over the HTTP services API; VLCKit behind
`PlayerEngine`, dynamically linked; v35 adapter only for now behind the version seam; open
source, maybe App Store later; commercial auto-skip with undo as the default, with Skip-button
and Off modes; shelves plus shows grid; write-back of resume position, watched, delete,
bookmarks; TDD with fast, injected-fake tests; future room for Live TV, the Videos library and
an iPhone app.

## Defaults the planner chose, not yet confirmed by the owner

tvOS 26 deployment target; MIT licence; Swift Testing; land 1 s before a break ends; 8 s undo
window; mark watched at 95 %; save position every 30 s; skip steps 30 s forward / 10 s back. The
owner was told about these twice and raised no objection, but never said yes. If one becomes
load-bearing, ask.

## Open risks and unknowns

- **VLCKit on tvOS** is the go/no-go. No clear official tvOS Swift package was found in a web
  search on 2026-11-14: options were 4.0 alpha builds (mostly community wrappers) or the older
  3.6 line. M0-3 must pick on real hardware, prove dynamic linking, and confirm the build has no
  GPL-only modules. If MPEG-2 playback is not acceptable, stop and take it to the owner.
- Every recording on basement is MPEG-2 in `.ts`/`.mpg`; AVPlayer cannot play them. That is why
  VLCKit was chosen. Backend HLS transcoding was considered and rejected.
- LGPL and App Store terms: commonly shipped (VLC itself is on the store) but not legally
  settled. Only matters if the owner goes to the App Store.
- The name "Mythwatch" passed a quick web search only. "Mythic" and "MythTV" are taken.
- `[verify]` markers in `BACKEND-V35.md` list each unconfirmed wire assumption and the task that
  must settle it.

## Owner preferences observed

- Wants to be asked real questions up front, then left alone; approves quickly when given a
  recommendation.
- Is new to Apple-platform dependency and licensing conventions; explain those plainly when they
  come up.
- Needs to be present for anything touching real hardware or writing to basement, and must
  nominate a sacrificial recording before M3-5 and M5-1.
