#!/usr/bin/env python3
"""Regenerate the bundled exercise catalogue for Packages/SetmioCatalogue from an openGym checkout.

    python3 -I scripts/catalogue/build_catalogue.py /path/to/openGym

The checkout must contain catalogue/exercises/<id>.json and catalogue/i18n/zh.json. Writes, deterministically
(sorted by numeric id, compact separators, UTF-8, no duplicate keys):

    Packages/SetmioCatalogue/Sources/SetmioCatalogue/Resources/exercises.json
    Packages/SetmioCatalogue/Sources/SetmioCatalogue/Resources/zh.json

Only upstream text is read. Media (catalogue/media/, browse/) is never opened, and the output is scanned for media
paths and URLs before it is written. The output is AGPL-3.0 upstream data (see Packages/SetmioCatalogue/NOTICE.md).
This script is Setmio's own and uses only the Python standard library. Run it with -I.
"""

import json
import os
import subprocess
import sys

# Fields written to exercises.json, in output order. Every full upstream entry has all of them.
EXERCISE_FIELDS = (
    "id", "name", "bodyPart", "equipment", "target", "secondaryMuscles",
    "category", "description", "instructions", "textSource",
)
STRING_FIELDS = ("id", "name", "bodyPart", "equipment", "target", "category", "description", "textSource")
# Upstream fields the app does not use yet. They are dropped on purpose (see Packages/SetmioCatalogue/README.md).
DROPPED_FIELDS = ("muscleMap", "femaleVariant", "maleVariant")
# Translation fields, in output order.
TRANSLATION_FIELDS = ("name", "description", "instructions")
# Nothing in the bundle may point at media or the network.
FORBIDDEN_SUBSTRINGS = ("media/", ".webp", ".mp4", ".gif", "http://", "https://", "gymvisual")

RESOURCE_DIR = os.path.join("Packages", "SetmioCatalogue", "Sources", "SetmioCatalogue", "Resources")


def fail(message):
    sys.exit("build_catalogue: " + message)


def reject_duplicate_keys(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate key %r" % key)
        obj[key] = value
    return obj


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f, object_pairs_hook=reject_duplicate_keys)
    except (OSError, ValueError) as error:
        fail("cannot read %s: %s" % (path, error))


def numeric_key(exercise_id):
    # Upstream ids are zero-padded numbers ("0025", "10187"); sort them numerically.
    if not exercise_id.isdigit():
        fail("non-numeric exercise id %r" % exercise_id)
    return int(exercise_id), exercise_id


def require_string(entry, key, where, allow_empty=False):
    value = entry.get(key)
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        fail("%s: field %r must be a non-empty string" % (where, key))
    return value


def require_string_list(entry, key, where, allow_empty):
    value = entry.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        fail("%s: field %r must be a list of non-empty strings" % (where, key))
    if not value and not allow_empty:
        fail("%s: field %r must not be empty" % (where, key))
    return value


def read_upstream_exercises(catalogue_dir):
    """Returns (full entries by id, alias stubs by id -> the full id they point at)."""
    exercise_dir = os.path.join(catalogue_dir, "exercises")
    full, stubs = {}, {}
    for name in sorted(os.listdir(exercise_dir)):
        if not name.endswith(".json"):
            continue
        stem = name[: -len(".json")]
        entry = load_json(os.path.join(exercise_dir, name))
        if not isinstance(entry, dict) or entry.get("id") != stem:
            fail("%s: id must equal the file name" % name)
        if "variantOf" in entry:
            if set(entry) != {"id", "variantOf"}:
                fail("%s: alias stubs may only contain id and variantOf" % name)
            stubs[stem] = entry["variantOf"]
        else:
            full[stem] = entry
    for stub_id, target_id in stubs.items():
        if target_id not in full:
            fail("alias stub %s points at %s, which is not a full entry" % (stub_id, target_id))
    return full, stubs


def build_exercise_record(entry, where, dropped):
    unknown = set(entry) - set(EXERCISE_FIELDS) - set(DROPPED_FIELDS)
    if unknown:
        # A new upstream field must be reviewed (it could carry media or URLs) before it is bundled.
        fail("%s: unexpected field(s) %s; review them before adding to the allow-list" % (where, sorted(unknown)))
    for key in DROPPED_FIELDS:
        if key in entry:
            dropped[key] = dropped.get(key, 0) + 1
    record = {}
    for key in EXERCISE_FIELDS:
        if key in ("secondaryMuscles", "instructions"):
            record[key] = require_string_list(entry, key, where, allow_empty=key == "secondaryMuscles")
        elif key in STRING_FIELDS:
            record[key] = require_string(entry, key, where, allow_empty=False)
        else:
            raise AssertionError(key)
    return record


def build_translations(table, full_ids):
    translations = {}
    for exercise_id in sorted(table, key=numeric_key):
        where = "i18n/zh.json[%s]" % exercise_id
        if exercise_id not in full_ids:
            fail("%s: no full exercise with this id" % where)
        source = table[exercise_id]
        if not isinstance(source, dict) or not set(source) <= set(TRANSLATION_FIELDS) or not source:
            fail("%s: only %s are allowed" % (where, ", ".join(TRANSLATION_FIELDS)))
        entry = {}
        for key in TRANSLATION_FIELDS:
            if key not in source:
                continue
            if key == "instructions":
                entry[key] = require_string_list(source, key, where, allow_empty=False)
            else:
                entry[key] = require_string(source, key, where)
        translations[exercise_id] = entry
    return translations


def encode(payload):
    return (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def check_no_media_references(name, data):
    lowered = data.decode("utf-8").lower()
    for needle in FORBIDDEN_SUBSTRINGS:
        if needle in lowered:
            fail("%s contains %r; media paths and URLs must not be bundled" % (name, needle))


def upstream_revision(root):
    try:
        result = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def main(argv):
    if len(argv) != 2:
        fail("usage: python3 -I scripts/catalogue/build_catalogue.py <openGym checkout>")
    upstream = os.path.abspath(argv[1])
    catalogue_dir = os.path.join(upstream, "catalogue")
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    out_dir = os.path.join(repo_root, RESOURCE_DIR)
    if not os.path.isdir(os.path.join(catalogue_dir, "exercises")):
        fail("%s has no catalogue/exercises directory" % upstream)

    full, stubs = read_upstream_exercises(catalogue_dir)
    dropped = {}
    exercises = []
    for exercise_id in sorted(full, key=numeric_key):
        exercises.append(build_exercise_record(full[exercise_id], "exercises/%s.json" % exercise_id, dropped))
    translations = build_translations(load_json(os.path.join(catalogue_dir, "i18n", "zh.json")), set(full))

    exercises_bytes = encode(exercises)
    check_no_media_references("exercises.json", exercises_bytes)
    zh_bytes = encode(translations)
    check_no_media_references("zh.json", zh_bytes)

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "exercises.json"), "wb") as f:
        f.write(exercises_bytes)
    with open(os.path.join(out_dir, "zh.json"), "wb") as f:
        f.write(zh_bytes)

    print("upstream revision: %s" % (upstream_revision(upstream) or "unknown (not a git checkout)"))
    print("exercises: %d written, %d alias stubs skipped" % (len(exercises), len(stubs)))
    print("dropped upstream fields: %s" % (", ".join("%s=%d" % kv for kv in sorted(dropped.items())) or "none"))
    for key in ("bodyPart", "equipment", "target", "textSource"):
        values = {}
        for record in exercises:
            values[record[key]] = values.get(record[key], 0) + 1
        print("%s (%d): %s" % (key, len(values), ", ".join("%s %d" % (v, n) for v, n in sorted(values.items()))))
    print("zh.json: %d entries, %d with name, %d with description, %d with instructions" % (
        len(translations),
        sum(1 for entry in translations.values() if "name" in entry),
        sum(1 for entry in translations.values() if "description" in entry),
        sum(1 for entry in translations.values() if "instructions" in entry),
    ))
    print("exercises.json: %d bytes" % len(exercises_bytes))
    print("zh.json: %d bytes" % len(zh_bytes))


if __name__ == "__main__":
    main(sys.argv)
