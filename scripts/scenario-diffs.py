#!/usr/bin/env python3
"""Word-level view of a scenario run's failures.jsonl.

Sentences are long; what matters is which typed word became which output word.
Words are aligned by position (a correction always replaces one token by one
token). Each line: count, typed word, expected word, actual word, grouped by
category and by kind:

  wrong  - the output differs from both the typed and the intended word
  missed - the typed word was left although something else was intended

Usage: scenario-diffs.py FAILURES.jsonl [--top N] [--category PREFIX] [--kind wrong|missed]
"""
import argparse
import collections
import json
import sys


def word_diffs(record):
    typed = record["input"].split()
    expected = record["expected"].split()
    actual = record["actual"].split()
    if not (len(typed) == len(expected) == len(actual)):
        yield ("misaligned", record["input"], record["expected"], record["actual"])
        return
    for t, e, a in zip(typed, expected, actual):
        if a == e:
            continue
        yield ("missed" if a == t else "wrong", t, e, a)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("failures")
    parser.add_argument("--top", type=int, default=40)
    parser.add_argument("--category", default="", help="only categories starting with this prefix")
    parser.add_argument("--kind", choices=["wrong", "missed", "misaligned"], help="only this kind")
    args = parser.parse_args(argv)

    groups = collections.defaultdict(collections.Counter)
    totals = collections.Counter()
    with open(args.failures, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            category = record["category"]
            if not category.startswith(args.category):
                continue
            for kind, typed, expected, actual in word_diffs(record):
                if args.kind and kind != args.kind:
                    continue
                groups[(category, kind)][(typed, expected, actual)] += 1
                totals[(category, kind)] += 1

    out = sys.stdout
    for key in sorted(groups):
        category, kind = key
        counter = groups[key]
        out.write(f"## {category} [{kind}] {totals[key]} words, {len(counter)} distinct\n")
        for (typed, expected, actual), count in counter.most_common(args.top):
            out.write(f"{count}\t{typed}\t{expected}\t{actual}\n")
        out.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
