# SetmioCatalogue

An offline exercise library for Setmio: 5,632 exercises from openGym, with English names and steps, Chinese names
(and Chinese steps for 1,324 of them), and pure search and filter functions. Foundation only, so it builds and tests
on macOS and Linux.

Licensing: the data under `Sources/SetmioCatalogue/Resources/` is AGPL-3.0. The Swift code is written for Setmio.
See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).

## Use

```swift
let catalogue = try ExerciseCatalogue.loadBundled()

let query = ExerciseQuery(text: "卧推", bodyParts: [.chest], equipment: [.barbell], language: .zh)
let results = catalogue.search(query)           // ordered by the Chinese name, then id
let chips = catalogue.facetCounts(for: query)   // target and equipment counts for the filter chips

let name = results.first?.localizedName(for: .zh)
let regions = results.first?.target?.regions ?? []   // body-map regions to highlight
```

## Layout

| Path | Contents |
|---|---|
| `Sources/SetmioCatalogue/Resources/exercises.json` | Full entries, sorted by numeric id (see "What is kept" below) |
| `Sources/SetmioCatalogue/Resources/zh.json` | Chinese translations keyed by id |
| `Sources/SetmioCatalogue/Model/` | Value types: exercises, vocabularies, body-map regions, query, language |
| `Sources/SetmioCatalogue/Catalogue/` | `ExerciseCatalogue` (loading, lookup, search, facets), search index, resource loader |
| `Tests/SetmioCatalogueTests/` | Swift Testing tests, including a check that every bundled word is a known case |

## Regenerate the data

From the Setmio repository root, with an openGym checkout:

```sh
python3 -I scripts/catalogue/build_catalogue.py /path/to/openGym
swift test --package-path Packages/SetmioCatalogue
```

The script reads only `catalogue/exercises/*.json` and `catalogue/i18n/zh.json`. It never opens `media/` or `browse/`,
and it refuses to write a media path or URL. The output is deterministic (sorted by numeric id, compact, UTF-8, no
duplicate keys). It stops on any upstream field it does not know, so a new field is reviewed before it is bundled.

### What is kept

- Per entry: `id`, `name`, `bodyPart`, `equipment`, `target`, `secondaryMuscles`, `category`, `description`,
  `instructions`, `textSource`.
- Dropped: `muscleMap` (246 entries), which the body map does not need because `target` drives it. `femaleVariant`
  and `maleVariant` (935 and 13 links), which only pointed at the female-figure media. The 922 `variantOf` stubs,
  which duplicate full entries and are not exercises of their own.

## When upstream changes

- **A new word** in `bodyPart`, `equipment` or `target`: it decodes to nil and `CatalogueDataTests` fails with the
  words to add. Add a case to `Model/Vocabulary.swift` with its `nameZH`. For a new target, also give it regions in
  `Model/MuscleMap.swift`. `VocabularyTests` requires every target to map to at least one region.
- **A new language**: add a case to `CatalogueLanguage` with its tag as the raw value. Extend the script to copy
  `i18n/<tag>.json` to `Resources/<tag>.json`, then regenerate. `loadBundled()` throws if a translation table is missing,
  so a half-added language fails at load time rather than showing English without warning.

## Known gaps

- `zh.json` has no Chinese descriptions. It has Chinese steps only for the 1,324 `exercisedb` entries. Other
  exercises show English steps and descriptions in Chinese.
- The Chinese text was produced with language-model assistance and has not been reviewed (see NOTICE.md).
- Chinese names sort by code point, not pinyin. This keeps the order identical on every platform.
- The Linux CI job (`.github/workflows/ci.yml`) does not run this package yet.

## Behaviour

- **Text**: case- and diacritic-insensitive. Every whitespace-separated word must appear in the English name or in the
  name for `query.language`, in any order. Names are folded once when the catalogue is built, so a keystroke is one
  pass over 5,632 precomputed keys (about 0.3 ms per search in a release build).
- **Facets**: each facet ignores its own selection, so choosing "chest" does not zero out "back". Every case is
  included, with 0 when nothing matches.
- **Unknown words** decode to nil instead of failing the whole library. The tests, not the runtime, catch them.
- **Body map**: `TargetMuscle.regions` gives each target its regions, and `MuscleRegion.side` gives the view each one is
  drawn on. The reasons for each mapping are in the comments in `Model/MuscleMap.swift`.
