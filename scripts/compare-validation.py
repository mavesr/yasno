# coding: utf-8
"""Compare semantic outcomes of two reproducible runs; ignores wall time and timing noise."""
import json
import hashlib
import sys
from pathlib import Path

if len(sys.argv) != 3:
    sys.exit('Usage: python3 scripts/compare-validation.py BASELINE_DIRECTORY CURRENT_DIRECTORY')
old_path, new_path = map(Path, sys.argv[1:])
def read_run(path):
    try:
        complete = json.loads((path / 'complete.json').read_text())
        if complete.get('schema') != 1 or complete.get('completed') is not True:
            sys.exit('Incomplete run: ' + str(path))
        blobs = {}
        for name in ['report.json', 'failures.jsonl']:
            data = (path / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != complete['files'][name]:
                sys.exit('Incomplete or changed artifact: ' + str(path / name))
            blobs[name] = data
        return json.loads(blobs['report.json']), [json.loads(s) for s in blobs['failures.jsonl'].splitlines()]
    except (OSError, ValueError, KeyError):
        sys.exit('Missing or invalid completion manifest: ' + str(path))

old, old_failures = read_run(old_path)
new, new_failures = read_run(new_path)
for field in ['schema', 'profile', 'seed', 'corpusSHA256', 'layouts']:
    if old[field] != new[field]:
        sys.exit('Not comparable: ' + field + ' changed; review a new baseline explicitly')
if old['total']['total'] != new['total']['total']:
    sys.exit('Not comparable: number of checks changed')

def failures(records):
    result = {item['id']: item for item in records}
    if len(records) != len(result):
        sys.exit('Invalid run: duplicate case IDs')
    return result

before, after = failures(old_failures), failures(new_failures)
regressions = [row for key, row in after.items() if key not in before]
changed = [row for key, row in after.items() if key in before and
           (row['actual'], row.get('target')) != (before[key]['actual'], before[key].get('target'))]
improvements = [key for key in before if key not in after]
# Scenario word-level misses are counted, not listed, so also compare category counts.
old_categories, new_categories = old.get('categories', {}), new.get('categories', {})
if set(old_categories) != set(new_categories):
    sys.exit('Not comparable: categories changed; review a new baseline explicitly')
worse = [key for key, stats in sorted(new_categories.items())
         if stats.get('passed', 0) < old_categories[key].get('passed', 0)
         or stats.get('different', 0) > old_categories[key].get('different', 0)]
print('New failing / non-matching cases:', len(regressions))
print('Changed non-matching suggestions:', len(changed))
print('Now matching:', len(improvements))
print('Categories with fewer passes or more wrong changes:', len(worse))
print('Required failures:', new['total']['requiredFailures'])
for key in worse[:30]:
    print(' ', key, 'passed', old_categories[key].get('passed', 0), '->', new_categories[key].get('passed', 0),
          'different', old_categories[key].get('different', 0), '->', new_categories[key].get('different', 0))
for row in (regressions + changed)[:30]:
    print(row['id'], repr(row['input']), '->', repr(row['actual']), 'expected', repr(row['expected']))
sys.exit(1 if regressions or changed or worse or new['total']['requiredFailures'] else 0)
