#!/usr/bin/env python3
"""The app's translations: the String Catalogs in Layland/Localization, whether each language
has all of them, and a way to put translations in. Adapted from Subtitles' tools/strings.py.

The English is the source code. SwiftUI looks up every string literal it shows (Text("…"),
Button("…"), .help("…")), and the code looks up the rest with String(localized: "…"); the
compiler lists them all for each file it builds (SWIFT_EMIT_LOC_STRINGS), and `sync` merges
those lists into Localizable.xcstrings, as Xcode does when it builds. A count is an Int put
into the string ("\\(count) files" is "%lld files"), and has a form per plural category of
each language, English's one and other included. InfoPlist.xcstrings holds the Info.plist's
words: the folder access prompts and the name of a saved scan's file type.

  tools/strings.py sync               build, then add new strings to the catalog
  tools/strings.py check [--build Debug|Release] [lang …]
                                      what is missing or broken; exit 1 if anything is.
                                      With --build, also what that build's code says that
                                      the catalog doesn't have yet (release.sh checks so)
  tools/strings.py import <lang> <file.json> [--table InfoPlist]
                                      put {key: string, or {category: string} for a count}
                                      into the catalog
"""

import glob
import json
import pathlib
import platform
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "Layland" / "Localization"
TABLES = {"Localizable": LOCALIZATION / "Localizable.xcstrings",
          "InfoPlist": LOCALIZATION / "InfoPlist.xcstrings"}
DERIVED = ROOT / "build" / "DerivedData"

# Settings ▸ Language lists the same (AppLanguage.all), and project.yml declares them.
LANGUAGES = ["es", "fr", "it", "pt-BR", "de", "nl", "tr", "ru", "ar", "hi",
             "ja", "ko", "vi", "uk", "zh-Hans"]

# The plural categories each language's integers fall into (CLDR). A count's form must be
# given for each; "other" always.
PLURALS = {
    "en": {"one", "other"},
    "es": {"one", "many", "other"}, "fr": {"one", "many", "other"},
    "it": {"one", "many", "other"}, "pt-BR": {"one", "many", "other"},
    "de": {"one", "other"}, "nl": {"one", "other"}, "tr": {"one", "other"},
    "ru": {"one", "few", "many", "other"}, "uk": {"one", "few", "many", "other"},
    "ar": {"zero", "one", "two", "few", "many", "other"}, "hi": {"one", "other"},
    "ja": {"other"}, "ko": {"other"}, "vi": {"other"}, "zh-Hans": {"other"},
}
# Required rather than merely allowed: "many" in the Romance languages is for millions, and
# falls back to "other", which says the same.
REQUIRED_PLURALS = {lang: cats - {"many"} if lang in ("es", "fr", "it", "pt-BR") else cats
                    for lang, cats in PLURALS.items()}

# What must come through a translation unchanged, when the English has it.
KEEP = ["Layland", "Gumroad", "Finder", "⌘", "⌥", "HTTP"]
# Where Apple's own name for one of those is another (Simplified Chinese's Finder is 访达).
KEEP_EXCEPT = {("zh-Hans", "Finder"): "访达"}
# What the app never shows, in any language.
BANNED = ["—"]  # the em dash

SPEC = re.compile(r"%(?:(\d+)\$)?(@|lld|llu|ld|lu|d|u|%)")


def specs(text):
    """The format arguments a string takes, by position."""
    out, n = {}, 0
    for m in SPEC.finditer(text):
        if m.group(2) == "%":
            continue
        n += 1
        out[int(m.group(1)) if m.group(1) else n] = m.group(2)
    return out


def load(table="Localizable"):
    return json.loads(TABLES[table].read_text())


def save(catalog, table="Localizable"):
    # Xcode's own layout, so a save from Xcode and one from here differ only in what changed.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    TABLES[table].write_text(text + "\n")


def is_plural(entry):
    return "plural" in entry.get("localizations", {}).get("en", {}).get("variations", {})


def english(key, entry):
    """The English for a key: its own English entry, or the key itself."""
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit")
    return unit["value"] if unit else key


# ── the code's strings ────────────────────────────────────────────────────────

def stringsdata(config):
    """The compiler's lists of a build's strings, one per source file still in the app: a
    file's list stays behind in DerivedData after the file is gone."""
    sources = {p.stem for p in (ROOT / "Layland").rglob("*.swift")}
    found = glob.glob(str(DERIVED / f"Build/Intermediates.noindex/Layland.build/{config}"
                                    "/Layland.build/Objects-normal/*/*.stringsdata"))
    return [p for p in found if pathlib.Path(p).stem in sources]


def code_keys(config):
    """{key: where} for every Localizable string in a build's code."""
    keys = {}
    for path in stringsdata(config):
        data = json.loads(pathlib.Path(path).read_text())
        source = pathlib.Path(data["source"]).relative_to(ROOT)
        for entry in data["tables"].get("Localizable", []):
            keys.setdefault(entry["key"], f"{source}:{entry['location']['startingLine']}")
    return keys


# ── sync ──────────────────────────────────────────────────────────────────────

def sync():
    subprocess.run(["xcodebuild", "-project", str(ROOT / "Layland.xcodeproj"), "-scheme", "Layland",
                    "-configuration", "Debug", "-destination", f"platform=macOS,arch={platform.machine()}",
                    "-derivedDataPath", str(DERIVED), "-quiet", "build"],
                   check=True)
    args = ["xcrun", "xcstringstool", "sync", str(TABLES["Localizable"])]
    for p in stringsdata("Debug"):
        args += ["--stringsdata", p]
    subprocess.run(args, check=True)
    # Back into this script's layout.
    save(load())
    catalog = load()
    stale = [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]
    for key in stale:
        print(f"no longer in the code: {key!r}")
    print(f"{len(catalog['strings'])} strings")


# ── check ─────────────────────────────────────────────────────────────────────

def check_table(lang, table):
    problems = []
    for key, entry in load(table)["strings"].items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        source = english(key, entry)
        plural = table == "Localizable" and is_plural(entry)
        if plural:
            en_forms = entry["localizations"]["en"]["variations"]["plural"]
            missing = REQUIRED_PLURALS["en"] - set(en_forms)
            if missing and lang == LANGUAGES[0]:
                problems.append(f"{key!r}: no English {', '.join(sorted(missing))} form")
        loc = entry.get("localizations", {}).get(lang)
        if not loc:
            problems.append(f"missing: {key!r}")
            continue
        if plural:
            forms = loc.get("variations", {}).get("plural")
            if forms is None:
                problems.append(f"{key!r}: a count wants plural forms")
                continue
            missing = REQUIRED_PLURALS[lang] - set(forms)
            extra = set(forms) - PLURALS[lang]
            if missing:
                problems.append(f"{key!r}: no {', '.join(sorted(missing))} form")
            if extra:
                problems.append(f"{key!r}: {', '.join(sorted(extra))} is not a {lang} category")
            texts = {cat: f["stringUnit"]["value"] for cat, f in forms.items()}
        else:
            if "stringUnit" not in loc:
                problems.append(f"{key!r}: not a count")
                continue
            texts = {"": loc["stringUnit"]["value"]}
        want = specs(source)
        for cat, text in texts.items():
            label = f"{key!r}" + (f" [{cat}]" if cat else "")
            if not text.strip():
                problems.append(f"{label}: empty")
                continue
            got = specs(text)
            # A plural form may leave the number out ("один" for one), never add or change one.
            if plural and cat != "other":
                if any(want.get(p) != t for p, t in got.items()):
                    problems.append(f"{label}: arguments {got} against {want}")
            elif got != want:
                problems.append(f"{label}: arguments {got} against {want}")
            for word in KEEP:
                if word in source and KEEP_EXCEPT.get((lang, word), word) not in text:
                    problems.append(f"{label}: lost {word!r}")
            for word in BANNED:
                if word in text:
                    problems.append(f"{label}: has {word!r}")
    return problems


def check(langs, config=None):
    bad = 0
    if config:
        known = load()["strings"]
        new = {k: w for k, w in code_keys(config).items() if k not in known}
        if not code_keys(config):
            print(f"no {config} build to read the code's strings from")
            bad += 1
        for key, where in sorted(new.items(), key=lambda kv: kv[1]):
            print(f"not in the catalog (tools/strings.py sync): {key!r} at {where}")
        bad += len(new)
    for lang in langs or LANGUAGES:
        problems = check_table(lang, "Localizable") + check_table(lang, "InfoPlist")
        bad += len(problems)
        print(f"{lang}: " + ("ok" if not problems else f"{len(problems)} problems"))
        for p in problems:
            print("   ", p)
    return bad


# ── import ────────────────────────────────────────────────────────────────────

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def import_(lang, path, table):
    catalog = load(table)
    strings = catalog["strings"]
    given = json.loads(pathlib.Path(path).read_text())
    unknown = []
    for key, value in given.items():
        if key not in strings:
            if table == "InfoPlist":
                strings[key] = {}
            else:
                unknown.append(key)
                continue
        locs = strings[key].setdefault("localizations", {})
        if isinstance(value, dict):
            locs[lang] = {"variations": {"plural": {cat: unit(v) for cat, v in value.items()}}}
        else:
            locs[lang] = unit(value)
    save(catalog, table)
    for key in unknown:
        print(f"not in the catalog, skipped: {key!r}")
    print(f"{lang}: {len(given) - len(unknown)} strings")


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    if args[0] == "sync":
        sync()
    elif args[0] == "check":
        config = None
        if args[1:2] == ["--build"]:
            config, args = args[2], args[2:]
        sys.exit(1 if check(args[1:], config) else 0)
    elif args[0] == "import" and len(args) in (3, 5):
        table = args[4] if len(args) == 5 and args[3] == "--table" else "Localizable"
        import_(args[1], args[2], table)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
