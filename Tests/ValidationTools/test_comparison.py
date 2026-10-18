# coding: utf-8
import json
import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.before = self.root / 'before'
        self.after = self.root / 'after'
        self.report = {'schema': 1, 'profile': 'quick', 'seed': 42, 'corpusSHA256': 'fixture', 'layouts': ['ABC'],
                       'total': {'total': 10, 'requiredFailures': 0}, 'p95Microseconds': 10}
        self.write(self.before, self.report, [])
        self.write(self.after, self.report, [])

    def write(self, root, report, failures):
        root.mkdir(exist_ok=True)
        (root / 'report.json').write_text(json.dumps(report))
        (root / 'failures.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in failures))
        files = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in ['report.json', 'failures.jsonl']}
        (root / 'complete.json').write_text(json.dumps({'schema': 1, 'completed': True, 'files': files}))

    def run_compare(self):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/compare-validation.py'), str(self.before), str(self.after)], capture_output=True, text=True)

    def failure(self, actual='wrong'):
        return {'id': 'case/1', 'input': 'typed', 'expected': 'correct', 'actual': actual}

    def test_same_outcomes_ignore_timing_noise(self):
        changed = dict(self.report, p95Microseconds=10000)
        self.write(self.after, changed, [])
        self.assertEqual(self.run_compare().returncode, 0)

    def test_new_failure_or_changed_suggestion_is_a_regression(self):
        self.write(self.after, self.report, [self.failure()])
        self.assertNotEqual(self.run_compare().returncode, 0)
        self.write(self.before, self.report, [self.failure('another')])
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_improvement_is_allowed_but_required_failure_is_not(self):
        self.write(self.before, self.report, [self.failure()])
        self.assertEqual(self.run_compare().returncode, 0)
        report = dict(self.report, total={'total': 10, 'requiredFailures': 1})
        self.write(self.after, report, [])
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_seed_or_corpus_changes_cannot_silently_rebaseline(self):
        for field, value in [('seed', 43), ('corpusSHA256', 'changed'), ('layouts', ['Russian'])]:
            self.write(self.after, dict(self.report, **{field: value}), [])
            self.assertNotEqual(self.run_compare().returncode, 0)

    def test_duplicate_case_ids_are_rejected(self):
        self.write(self.after, self.report, [self.failure(), self.failure()])
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_changed_layout_is_not_hidden_by_identical_text(self):
        before = dict(self.failure('shared'), target='Russian')
        after = dict(self.failure('shared'), target='Ukrainian')
        self.write(self.before, self.report, [before])
        self.write(self.after, self.report, [after])
        self.assertNotEqual(self.run_compare().returncode, 0)

    def test_incomplete_or_changed_artifacts_cannot_look_like_improvements(self):
        (self.after / 'complete.json').unlink()
        self.assertNotEqual(self.run_compare().returncode, 0)
        self.write(self.after, self.report, [])
        (self.after / 'failures.jsonl').write_text(json.dumps(self.failure()) + '\n')
        self.assertNotEqual(self.run_compare().returncode, 0)

if __name__ == '__main__':
    unittest.main()
