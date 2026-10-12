# Notices for SetmioCatalogue

## What is covered by which licence

| Files | Licence |
|---|---|
| `Sources/SetmioCatalogue/Resources/**` (`exercises.json`, `zh.json`) | **GNU AGPL-3.0**, full text in [LICENSE](LICENSE). Exercise text and translations from openGym. |
| `Sources/SetmioCatalogue/**/*.swift`, `Tests/**`, `Package.swift`, `README.md`, `NOTICE.md` | Written for Setmio. Not copied from openGym or ExerciseDB. |
| `scripts/catalogue/build_catalogue.py` (repository root) | Written for Setmio. Not copied from openGym or ExerciseDB. |

Only the data under `Sources/SetmioCatalogue/Resources/` is AGPL-3.0. The Swift code in this package was written for Setmio. The AGPL text is in LICENSE and applies to the data files only.

## Exercise text: openGym

The bundled exercise names, descriptions, steps and muscle lists come from openGym.

- openGym: Copyright (C) 2026 Duarte Santos. https://github.com/DuarteSantos8/openGym
- Licence: GNU AGPL-3.0 (see LICENSE in this folder).
- Snapshot: `catalogue/` at openGym commit `464355ef43d4c8f8a4e0bb6db9c2af7f240593b5`. Regenerate with `scripts/catalogue/build_catalogue.py`.
- Upstream's additional permission for app-store distribution (section 7 of its NOTICE.md) is openGym's own grant for openGym's app. It is not repeated here and does not apply to this copy of the data.

The bundle holds 5,632 exercises. 4,308 have `"textSource": "opengym"`. 1,324 have `"textSource": "exercisedb"` (see the next section).

## Entries derived from ExerciseDB (MIT)

The 1,324 entries with `"textSource": "exercisedb"` keep names, muscles and instructions that originate from [ExerciseDB v1](https://exercisedb.dev/) by AscendAPI. openGym received them through [hasaneyldrm/exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset), under the MIT licence reproduced below, as openGym's NOTICE.md does.

```
MIT License

Copyright (c) 2026 Hasan Emir Yıldırım

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation and data files (the "Software"),
to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Everything else in the bundle (the `opengym` entries, every description, and the translations) is covered by openGym's AGPL-3.0.

## Translations: Chinese (`zh.json`)

`zh.json` is copied without edits from openGym's `catalogue/i18n/zh.json`. It has a Chinese name for every exercise, Chinese steps for the 1,324 `exercisedb` entries, and no Chinese descriptions. Missing fields fall back to English.

Provenance: the Chinese text was produced with language-model assistance and has not been reviewed by a human translator. This is the maintainers' statement made at import. openGym's NOTICE.md records the same kind of origin only for its Brazilian Portuguese translations, and it does not say how the Chinese file was produced. Treat the Chinese text as unreviewed until upstream or a native reviewer confirms it.

## Media: not included

No exercise images or animations are included. The pictures and animations in openGym belong to Gym visual (gymvisual.com) and are not licensed for reuse in other software. The bundled data refers to no media path and no URL, and the build script refuses to write either. Do not add media from openGym to this package.
