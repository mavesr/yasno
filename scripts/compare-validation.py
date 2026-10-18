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
print('New failing / non-matching cases:', len(regressions))
print('Changed non-matching suggestions:', len(changed))
print('Now matching:', len(improvements))
print('Required failures:', new['total']['requiredFailures'])
for row in (regressions + changed)[:30]:
    print(row['id'], repr(row['input']), '->', repr(row['actual']), 'expected', repr(row['expected']))
sys.exit(1 if regressions or changed or new['total']['requiredFailures'] else 0)
