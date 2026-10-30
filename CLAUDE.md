# Topdeck

macOS notch and utility app, built on ILoveNotch. Read `docs/topdeck-plan.md` first: it holds the
scope, source and licence rules, and the design for each branch.

Everything is named Topdeck. Types that describe the notch itself (`NotchState`, `NotchFeature`) keep
that word. No upstream project names outside credits.

## Working on this repo

- Implementation runs locally in Sonnet or Haiku subagents, on a branch per feature. The primary
  session reviews and merges.
- Do not merge to `main` before review.
- Stay inside the feature's folder. Touch shared files (`AppDelegate.swift`, `Settings.swift`,
  `project.yml`, `Package.swift`, `FeatureID`) only for the few lines that register your feature.
- Put logic in AppKit-free code and test it. Warnings are errors in our own targets.
- Final report in Chinese: what changed, what was verified, what still needs a real Mac. Its last line
  is `完成时间：HH:MM`, read with `date '+%H:%M'`, or `完成时间：无法读取` if commands cannot run. Do not
  guess the time.

## Conventions

- Match the surrounding code: comment density, naming, idiom.
- Default to no secondary labels or helper text in UI. Let layout explain. Accessibility labels stay.
- `xcodebuild` always takes `-derivedDataPath <temp dir>.noindex`. Delete that directory afterwards.
  Before reporting finished work, run
  `mdfind 'kMDItemKind == "Application" && kMDItemFSName == "Topdeck*"c'` and delete stray build copies.
- No new private API unless the plan names it for your branch.
- A licence check (`make licenses`) needs the MIT SPDX header on every Swift file and every dependency
  in `THIRD_PARTY_NOTICES.md`.
