# Topdeck

macOS notch and utility app, built on ILoveNotch. Read `docs/topdeck-plan.md` first: it holds the
scope, source and licence rules, and the design for each branch.

Everything is named Topdeck. Types that describe the notch itself (`NotchState`, `NotchFeature`) keep
that word. No upstream project names outside credits.

## Cloud sessions

- The VM cannot compile this app. Push your branch, then read CI through `gh api`
  (`repos/fredcu/Topdeck/actions/runs?branch=<branch>`, then that run's `jobs` and `logs`). `gh pr`
  and `gh issue` are blocked. Fix failures and push until CI is green. Do not say work is done
  before that.
- Stay inside your task's feature folder. Touch shared files (`AppDelegate.swift`, `Settings.swift`,
  `project.yml`, `Package.swift`, `FeatureID`) only for the few lines that register your feature.
- Do not merge to `main`. Fred's primary session reviews and merges.
- Put logic in code with no AppKit and test it. Warnings are errors in our own targets.
- Final report in Chinese: what changed, what CI proved, what still needs a real Mac. Its last line
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
