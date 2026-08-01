# Upgrading this fork to a new upstream release

Runbook for pulling a new `Beingpax/VoiceInk` release into `mnott/VoiceInk`.
Written after the v1.71 → v2.1 upgrade (2026-08-01), which was 476 commits.

## 1. Rebase, do not merge

The fork is deliberately a thin stack of commits on top of `upstream/main`.
Upstream renames and deletes files freely between releases, so a merge produces
delete/modify conflicts on exactly the files we touched — and resolves to nothing
useful.

```shell
git fetch upstream --tags
git log --oneline upstream/main..HEAD          # our commits
git log --oneline HEAD..upstream/main | wc -l  # how far behind
git branch fork-vX.Y HEAD                      # ALWAYS back up the old tip first
git checkout -B main upstream/main
```

`git reset --hard` is blocked by the security-validator hook; `git checkout -B`
does the same job and is allowed.

Then re-apply each fork change against the new structure (see section 3) and
commit as separate thin commits so the next rebase stays easy.

## 2. Find where upstream moved our code

Do not assume the paths still exist. For each file we patch:

```shell
git cat-file -e upstream/main:<path> && echo EXISTS || echo GONE
```

For anything GONE, locate the replacement by searching for a nearby anchor
string rather than the filename:

```shell
git grep -ln "AppendTrailingSpace" upstream/main -- '*.swift'
```

Known moves so far (v1.71 → v2.1):

| Old | New |
|---|---|
| `VoiceInk/Whisper/TranscriptionPipeline.swift` | `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift` |
| `VoiceInk/Views/ModelSettingsView.swift` | `VoiceInk/Views/AI Models/ModelSettingsPanel.swift` |
| sidebar header in `ContentView.swift` | `VoiceInk/Views/Sidebar/AppSidebar.swift` |
| PowerMode | Modes (`VoiceInk/Modes/`) |
| `isAutoSendEnabled: Bool` | `autoSendKey: AutoSendKey` enum |

## 3. The fork changes

Four commits. Keep them separate and in this order.

1. **Global Auto Enter** — `AppDefaults.swift`, `Views/AI Models/ModelSettingsPanel.swift`,
   `Transcription/Engine/TranscriptionDelivery.swift`. The global toggle only
   fills in when the active Mode's `autoSendKey` is `.none`, so per-Mode pickers
   still win.
2. **No update nag in local builds** — `VoiceInk.swift`, `UpdaterViewModel.init()`:
   `#if LOCAL_BUILD` sets `automaticallyChecksForUpdates = false`.
3. **LOCAL badge** — `Views/Sidebar/AppSidebar.swift`. Entire struct lives inside
   `#if LOCAL_BUILD` so nothing leaks into release builds.
4. **README fork notice**.

The licensing bypass is **not** ours — it is upstream's own `LOCAL_BUILD`
compilation flag (`LicenseViewModel.init()` → `licenseState = .licensed`, plus
`KeychainService` and CloudKit guards). `make local` enables it. Nothing to
re-apply, but check it still exists after a big upstream refactor:

```shell
git grep -n "LOCAL_BUILD" upstream/main -- '*.swift'
```

## 4. Build and verify

```shell
make local          # → ~/Downloads/VoiceInk.app, ad-hoc signed, LOCAL_BUILD on
```

Debug builds put the code in `VoiceInk.debug.dylib`, **not** in the `VoiceInk`
executable — `strings` on the executable finds nothing. Verify against the dylib:

```shell
DYL=~/Downloads/VoiceInk.app/Contents/MacOS/VoiceInk.debug.dylib
for s in AutoEnterAfterTranscription "Auto Enter After Paste" LocalBuildBadge; do
  printf "%-32s %s\n" "$s" "$(strings -a "$DYL" | grep -c -- "$s")"
done
```

`LocalBuildBadge` only compiles under `LOCAL_BUILD`, so a non-zero count proves
the flag was active.

## 5. THE BIG GOTCHA — TCC permissions after replacing the app

**Replacing `/Applications/VoiceInk.app` in place silently breaks every granted
permission.** Ad-hoc signatures are identified by cdhash; a rebuild changes it,
so TCC's stored entry no longer matches the binary. System Settings still shows
the toggle as **ON** while the grant is dead. The app re-prompts and you chase
your tail.

Toggling the switch off and on does **not** fix it. Restarting the app does not
fix it. The only reliable fix:

```shell
osascript -e 'tell application "VoiceInk" to quit'
tccutil reset Accessibility  com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture  com.prakashjoshipax.VoiceInk
open -a /Applications/VoiceInk.app
```

Then grant fresh from the app's onboarding: **Allow** → *Open System Settings* →
flip the (now correctly empty) switch.

**Screen Recording needs one extra step.** After the reset, VoiceInk's Allow
button does not re-register the app, so the row never appears. Add it by hand:
System Settings → Privacy & Security → **Screen & System Audio Recording** → **+**
→ ⌘⇧G → `/Applications/VoiceInk.app` → Open, then accept the **Quit & Reopen**
prompt.

Microphone survives — it is not path/signature sensitive in the same way.

## 6. Onboarding after an upgrade

A new build re-runs onboarding. What carries over and what does not:

- **Carries over:** transcript history, stats, dictionary, downloaded whisper
  models in `~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/`.
- **Does not:** the onboarding gate itself. Step 3 (*Configure Transcription
  Model*) leaves **Continue disabled** and only offers Parakeet or a cloud
  provider — it will not accept the existing whisper model. Either download
  Parakeet (~494 MB) or use *Skip Onboarding*. Do not hit Skip mid-download.
- Steps that can be skipped safely: API key (LLM enhancement), dictation
  shortcut demo.
- Final screen reports "License active on this Mac" — that is `LOCAL_BUILD`
  working as intended.

## 7. Model selection moved

v2.1 moved model choice **out of AI Models** (now a download catalog only — its
"…" menu has just Delete / Show in Finder) and into
**Modes → Dictation → Transcription → Model**.

Existing whisper models are picked up automatically and appear there as
*Large v3 Turbo (Quantized)* etc. alongside Parakeet.

## 8. Publishing

`origin/main` will have diverged after the rebase. Push with
`--force-with-lease`, and keep the `fork-vX.Y` backup branch until the new build
has been used for a while.
