# Lessons

## A negative grep is not evidence of absence

**What went wrong**: Twice in one session a defect was reported that did not exist.
`strings` on a release binary did not contain a short string literal, which was read
as "the feature is missing" — Swift stores strings of 15 bytes or fewer inline in
code rather than in a literal section, so `strings` can never find them. Later, a
grep for `sparkle:version="` found nothing and was reported as a missing attribute;
it was present as an XML *element*, which is the correct modern syntax.

**The rule**: Before reporting something absent, confirm the search could have found
it if it were present. Prefer a check that fails loudly when the premise is wrong —
comparing timestamps, parsing the file properly, or testing behaviour — over a grep
whose silence has several possible meanings. A wrong "this is broken" costs more
than the check would have.

**Date**: 2026-08-07

---

## Never suspend a process that holds a keyboard event tap

**What went wrong**: lldb was attached to the running app to inspect its
in-memory state. Attaching stops the process; the app holds a global keyboard
event tap, so while it was stopped, keyboard input stalled system-wide — the
operator experienced broken typing in an unrelated app.

**The rule**: Never attach a debugger to, SIGSTOP, or otherwise suspend an app
that owns an event tap while the operator is using the machine. To inspect
runtime state, add temporary logging and read the unified log instead.

**Date**: 2026-08-07

---

## The operator installs and relaunches the app, never the agent

**What went wrong**: After a successful build, the agent killed the running app,
replaced it in /Applications, and relaunched it — all unannounced, while the
operator was actively using the machine.

**The rule**: The agent's job ends at `make local` succeeding. When a new build
is ready, say so, and say what to test. The operator decides when to swap the
installed app and restart it. No kill, no rm/ditto into /Applications, no `open`.

**Date**: 2026-08-07

---

## Never run the app-hosted test suite from an agent session

**What went wrong**: `xcodebuild ... test` was launched to verify a fix. The test
bundle is hosted inside the VoiceInk app, so running it launches the full GUI app
(recorder panel, menu bar item, windows) on the operator's screen while they are
using it.

**The rule**: From an agent session, verify with `make local` (build only). The
hosted test suite is run by the operator, from Xcode or a terminal, at a moment
they choose. If a pure decision-table function must be verified immediately,
compile it standalone in the scratchpad instead of running the app-hosted suite.

**Date**: 2026-08-07

---

## Never grant a background agent permission to quit applications

**What went wrong**: A probe agent was dispatched with permission to use `osascript`
to activate and quit applications, so it could set up and tear down a test app. It
quit the operator's terminal emulator instead, killing a live working session.

**Why the guard failed**: The brief said "do not quit anything you did not start".
That instruction is unenforceable — the agent had no reliable way to tell its own
target apart from the operator's session, and the capability was already granted.
A constraint expressed in prose does not constrain a capability granted in fact.

**The rule**: Background agents get no capability to quit, hide, activate, or focus
applications. If a test genuinely needs app lifecycle control, it runs in the
foreground where the operator can see and stop it. Prefer a target the operator is
not using, and prefer leaving it running over cleaning it up.

**Date**: 2026-08-07

---

## Look for the project's own build target before hand-rolling build flags

**What went wrong**: Roughly an hour was spent guessing `xcodebuild` flag
combinations to get a locally runnable build — first stripping code signing
(`CODE_SIGNING_ALLOWED=NO`), which removes entitlements and made the app trap at
launch inside the CoreData/CloudKit setup path; then re-enabling signing, which
failed because the iCloud entitlements demand a provisioning profile that ad-hoc
signing can never satisfy.

**What was actually there**: the project already shipped a `make local` target with
its own xcconfig and a second entitlements file carrying no iCloud keys, plus a
compilation condition that switches CoreData to the no-CloudKit branch. It had
solved the problem properly, and the whole detour was avoidable.

**The rule**: Before constructing a build invocation by hand, read the Makefile,
scripts directory, and CI config. A project that can be built locally usually
documents how, and the maintained path handles constraints that are not obvious
from the outside.

**Date**: 2026-08-07

---

## Ad-hoc signed builds lose their Accessibility grant on every rebuild

**What went wrong**: After installing a rebuilt app, no global shortcut worked at
all. This was diagnosed as a code regression and chased through the event-tap
implementation, including a plausible but entirely wrong theory about two shortcuts
fighting over a shared modifier. A conflict-validation fix was nearly written for a
conflict that did not exist.

**The actual cause**: macOS keys Accessibility permission for an ad-hoc signed app
by code hash. Every rebuild changes that hash, so the grant silently stops applying
and the event tap cannot be created. Nothing in the app reports this clearly.

**The rule**: When global hotkeys stop working after a rebuild, verify the
Accessibility grant before reading any application code. The give-away is that
in-app key capture still works (it uses a local monitor) while global shortcuts do
not (they need the tap). Re-grant after every rebuild, or expect the symptom again.

**Date**: 2026-08-07

---

## Do not diagnose from a launcher stub or a stale process id

**What went wrong**: Twice, a confident conclusion was drawn from the wrong artifact.
A feature was declared absent after grepping a small launcher executable, when the
real code lived in the separate debug dylib beside it. Later, a UI query returned
"no menu bar item" because the automation tool had cached a process id belonging to
an instance that had already been killed.

**The rule**: Confirm you are inspecting the artifact that is actually running.
Check the size of a binary before concluding a symbol is missing, and re-resolve
process ids after any restart rather than trusting a cached handle.

**Date**: 2026-08-07

---

## A stored AXUIElement is not a durable handle

**What went wrong**: A "pin this text field" feature stored the `AXUIElement`
returned by `kAXFocusedUIElementAttribute`. It broke almost immediately in real use:
many applications destroy and recreate their focused element when focus moves, and
focus moves as soon as any other panel appears. The stored reference then returns
`kAXErrorInvalidUIElement` and the target looks permanently dead.

**The rule**: Persist durable identity — the process and its window — and re-resolve
the live element at the moment of use. Keep the cached element only as a fast path.
Distinguish "the window is gone" from "the app is alive but nothing is focused";
they look similar at the API level and mean very different things to the user.

**Date**: 2026-08-07
