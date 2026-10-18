#!/usr/bin/env python3
"""Download and prepare the external test corpora for the scenario validation.

Nothing here ships with the app. Files are pinned by release tag and SHA-256,
cached in .build/testdata/cache and converted into compact TSV files that
YasnoValidate reads from .build/testdata/prepared.

    python3 scripts/fetch-testdata.py              # all sources
    python3 scripts/fetch-testdata.py --no-noncommercial

Sources marked noncommercial are CC BY-NC-SA: fine for local testing of a
personal project, never committed to the repository or redistributed.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys
import unicodedata
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / ".build" / "testdata"
UD = "https://raw.githubusercontent.com/UniversalDependencies/{repo}/r2.17/{name}"

# (language, repository, files, license, noncommercial)
TREEBANKS = [
    ("ru", "UD_Russian-Taiga", ["ru_taiga-ud-train-a", "ru_taiga-ud-train-b", "ru_taiga-ud-train-c",
                                "ru_taiga-ud-train-d", "ru_taiga-ud-train-e", "ru_taiga-ud-dev",
                                "ru_taiga-ud-test"], "CC BY-SA 4.0", False),
    ("ru", "UD_Russian-GSD", ["ru_gsd-ud-train", "ru_gsd-ud-dev", "ru_gsd-ud-test"], "CC BY-SA 4.0", False),
    ("uk", "UD_Ukrainian-ParlaMint", ["uk_parlamint-ud-train", "uk_parlamint-ud-dev", "uk_parlamint-ud-test"],
     "CC BY-SA 4.0", False),
    ("uk", "UD_Ukrainian-IU", ["uk_iu-ud-train", "uk_iu-ud-dev", "uk_iu-ud-test"], "CC BY-NC-SA 4.0", True),
    ("en", "UD_English-EWT", ["en_ewt-ud-train", "en_ewt-ud-dev", "en_ewt-ud-test"], "CC BY-SA 4.0", False),
    ("de", "UD_German-GSD", ["de_gsd-ud-train", "de_gsd-ud-dev", "de_gsd-ud-test"], "CC BY-SA 4.0", False),
]
TYPO_LISTS = [
    ("ru", "kartaslov", "https://raw.githubusercontent.com/dkulagin/kartaslov/"
     "master/dataset/orfo_and_typos/orfo_and_typos.L1_5.csv",
     "CC BY-NC-SA 4.0", True),
    ("en", "codespell", "https://raw.githubusercontent.com/codespell-project/codespell/v2.4.1/"
     "codespell_lib/data/dictionary.txt", "CC BY-SA 3.0", False),
]
PINNED = json.loads((ROOT / "scripts" / "testdata-sha256.json").read_text())

LETTERS = {
    "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
    "en": "abcdefghijklmnopqrstuvwxyz",
    "de": "abcdefghijklmnopqrstuvwxyzäöüß",
}
LATIN = LETTERS["en"]
PUNCTUATION = set(".,!?;:-\"'()%")
REPLACE = {"«": '"', "»": '"', "„": '"', "“": '"', "”": '"', "’": "'", "‘": "'", "ʼ": "'", "`": "'",
           "—": "-", "–": "-", "…": "...", " ": " "}
# One prepared language never needs more sentences than this; Taiga alone has 127k.
MAX_SENTENCES = 60_000


def fetch(url, key, update):
    cache = OUT / "cache" / key
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        print("download", url, file=sys.stderr)
        with urllib.request.urlopen(url, timeout=300) as response:
            data = response.read()
        cache.write_bytes(data)
    data = cache.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if update:
        PINNED[key] = digest
    elif PINNED.get(key) != digest:
        sys.exit(f"Checksum mismatch for {key}: {digest}. Delete the cache file or re-pin with --update-pins.")
    return data.decode("utf-8")


def normalize(text):
    text = unicodedata.normalize("NFC", text.replace("́", ""))
    for old, new in REPLACE.items():
        text = text.replace(old, new)
    return re.sub(r"\s+", " ", text).strip()


def typeable(text, language):
    allowed = set(LETTERS[language]) | set(LATIN) | PUNCTUATION | set("0123456789 ")
    return all(ch.lower() in allowed for ch in text)


def sentences(conllu, language):
    """Yield (text, typos) where typos are (typed, correct) from Typo=Yes|CorrectForm."""
    text, typos = None, []
    for line in conllu.splitlines():
        if line.startswith("# text = "):
            text, typos = line[9:], []
        elif line and line[0].isdigit():
            columns = line.split("\t")
            if len(columns) == 10 and "Typo=Yes" in columns[5]:
                match = re.search(r"CorrectForm=([^|]+)", columns[9])
                if match:
                    typos.append((normalize(columns[1]), normalize(match.group(1))))
        elif not line and text is not None:
            yield text, typos
            text = None


def prepare_sentences(language, noncommercial, update):
    seen, rows = set(), []
    for lang, repo, names, _, nc in TREEBANKS:
        if lang != language or (nc and not noncommercial):
            continue
        for name in names:
            conllu = fetch(UD.format(repo=repo, name=name + ".conllu"), name + ".conllu", update)
            for raw, typos in sentences(conllu, language):
                text = normalize(raw)
                words = [w for w in re.split(r"[\s\-]+", text) if any(c.isalpha() for c in w)]
                if not (3 <= len(words) <= 40) or not typeable(text, language) or text in seen:
                    continue
                native = set(LETTERS[language]) - set(LATIN) if language in ("ru", "uk") else set(LATIN)
                if not any(c.lower() in native for c in text):
                    continue
                seen.add(text)
                mixed = language in ("ru", "uk") and any(c.lower() in LATIN for c in text)
                pairs = ";".join(f"{a}>{b}" for a, b in typos if a != b and "\t" not in a + b)
                rows.append((repo, "m" if mixed else "-", text, pairs))
    # Deterministic, source-balanced cap: interleave treebanks rather than truncate one.
    if len(rows) > MAX_SENTENCES:
        step = len(rows) / MAX_SENTENCES
        rows = [rows[int(i * step)] for i in range(MAX_SENTENCES)]
    return rows


def prepare_typos(language, noncommercial, update):
    rows = []
    word = re.compile(f"^[{LETTERS[language]}]+$")
    for lang, key, url, _, nc in TYPO_LISTS:
        if lang != language or (nc and not noncommercial):
            continue
        data = fetch(url, key + pathlib.Path(url).suffix, update)
        for line in data.splitlines():
            if key == "kartaslov":
                parts = line.split(";")
                if len(parts) != 3 or parts[0] == "CORRECT":
                    continue
                correct, typo, weight = parts[0].strip(), parts[1].strip(), parts[2].strip()
            else:  # codespell: wrong->right[, other] [reason]
                if "->" not in line:
                    continue
                typo, targets = line.split("->", 1)
                targets = [t.strip() for t in targets.split(",") if t.strip()]
                if len(targets) != 1:
                    continue
                correct, weight = targets[0], "1"
            if len(correct) >= 3 and word.match(correct) and word.match(typo) and typo != correct:
                rows.append((typo, correct, weight, key))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-noncommercial", action="store_true", help="skip CC BY-NC-SA sources")
    parser.add_argument("--update-pins", action="store_true", help="record new checksums (maintainers only)")
    args = parser.parse_args()
    noncommercial = not args.no_noncommercial
    prepared = OUT / "prepared"
    prepared.mkdir(parents=True, exist_ok=True)
    manifest = {"schema": 1, "noncommercial": noncommercial, "files": {}}
    for language in ("ru", "uk", "en", "de"):
        rows = prepare_sentences(language, noncommercial, args.update_pins)
        # UD typo annotations go into the shared typo list as real, in-context errors.
        typos = prepare_typos(language, noncommercial, args.update_pins)
        typos += [(a, b, "1", "ud") for _, _, _, pairs in rows for a, b in
                  (p.split(">", 1) for p in pairs.split(";") if p)]
        for name, data in ((f"sentences-{language}.tsv", rows), (f"typos-{language}.tsv", typos)):
            text = "".join("\t".join(row) + "\n" for row in data)
            (prepared / name).write_text(text, encoding="utf-8")
            manifest["files"][name] = {"rows": len(data), "sha256": hashlib.sha256(text.encode()).hexdigest()}
        print(f"{language}: {len(rows)} sentences, {len(typos)} typo pairs", file=sys.stderr)
    manifest["sources"] = [
        {"language": l, "source": r, "license": lic, "noncommercial": nc} for l, r, _, lic, nc in TREEBANKS
    ] + [{"language": l, "source": k, "license": lic, "noncommercial": nc} for l, k, _, lic, nc in TYPO_LISTS]
    (prepared / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    if args.update_pins:
        (ROOT / "scripts" / "testdata-sha256.json").write_text(json.dumps(PINNED, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
