# omnilect (Flutter app)

Flutter app for offline MITx / MIT OpenLearning course access. See the
repo-root `CLAUDE.md` for platform, auth, and API details.

## Definition of done

Before declaring any task complete, run:

```bash
cd dart/app
fvm flutter analyze
```

The only acceptable output is `No issues found!`. **Every finding must be
fixed — including `info`-level notes.** Do not hand a task back to the user
while the analyzer still prints anything else.

- For mechanical lints (import ordering, unused imports, trailing commas,
  etc.), try `fvm dart fix --apply` first — it resolves most of them in
  bulk.
- For lints `dart fix` cannot handle (e.g. `use_setters_to_change_properties`,
  design-level warnings), fix them by hand. Do not silence a lint with
  `// ignore:` unless there is a concrete reason and it is commented why.
- The lint ruleset lives in `dart/app/analysis_options.yaml` (extends
  `very_good_analysis`). If a rule genuinely does not fit the project,
  disable it in that file rather than scattering ignores across the code.

## Flavors

Two entrypoints: `lib/main_dev.dart` and `lib/main_prod.dart`. Both call
`FlavorConfig.flavor = Flavor.dev|prod` before `bootstrap()`. Firebase
options, launcher icons, and analytics routing branch on
`FlavorConfig.isDev` / `isProd`.
