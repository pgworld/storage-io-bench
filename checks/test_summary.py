#!/usr/bin/env python3
"""CSV-only tests: never run fio or read benchmark data files."""
import csv
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'summarize.sh'


def write_csv(path, rows):
    with path.open('w', encoding='utf-8-sig', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'storage-results' / 'saved result'
        self.folder.mkdir(parents=True)
        write_csv(self.folder / 'summary.csv', [
            dict(profile='random_read_high_qd', block_bytes=4096, queue_depth=128, read_GiB_s_median=8),
            dict(profile='seq_read', block_bytes=1048576, queue_depth=32, read_GiB_s_median=4),
            dict(profile='random_read_low_qd', block_bytes=4096, queue_depth=1, read_GiB_s_median=.5)])

    def run_summary(self, name=None):
        return subprocess.run(['sh', str(SCRIPT), name or str(self.folder)], cwd=str(self.root),
                              capture_output=True, text=True, timeout=10)

    def read_output(self):
        with (self.folder / 'normalized.csv').open(encoding='utf-8-sig', newline='') as f:
            return list(csv.DictReader(f))

    def test_three_columns_use_useful_payload_and_preserve_inputs(self):
        write_csv(self.folder / 'workload_comparison.csv', [dict(
            workload='embedding_lookup_512b', useful_GiB_s_median=.0625, storage_GiB_s_median=.5)])
        before = {p.name: p.read_bytes() for p in self.folder.iterdir()}
        result = self.run_summary()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.read_output()
        self.assertEqual(list(rows[0]), ['workload', 'effective_bw_GiB_s', 'normalized_to_seq_read'])
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]['normalized_to_seq_read'], '1.000000')
        self.assertEqual(rows[2]['normalized_to_seq_read'], '2.000000')
        self.assertEqual(rows[3]['workload'], 'legacy_uniform_4KiB_python_512B_payload_QD1')
        self.assertEqual(rows[3]['effective_bw_GiB_s'], '0.062500')
        self.assertEqual(rows[3]['normalized_to_seq_read'], '0.015625')
        for name, contents in before.items():
            self.assertEqual((self.folder / name).read_bytes(), contents)
        self.assertEqual({p.name for p in self.folder.iterdir()}, set(before) | {'normalized.csv'})
        self.assertEqual(self.run_summary().returncode, 0)
        self.assertEqual(self.read_output(), rows)

    def test_folder_name_only_and_fio_only(self):
        result = self.run_summary('saved result')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.read_output()), 3)

    def test_macos_workers_and_matched_sequential_rows(self):
        write_csv(self.folder / 'summary.csv', [
            dict(profile='seq_read', block_bytes=1048576, queue_depth=1, jobs=4, engine='psync', read_GiB_s_median=4),
            dict(profile='random_read_low_qd', block_bytes=4096, queue_depth=1, jobs=1, engine='psync', read_GiB_s_median=.5),
            dict(profile='random_read_high_qd', block_bytes=4096, queue_depth=1, jobs=4, engine='psync', read_GiB_s_median=1),
            dict(profile='matched_seq_high_qd', block_bytes=4096, queue_depth=1, jobs=4, engine='psync', read_GiB_s_median=2)])
        result = self.run_summary()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.read_output()
        self.assertEqual(len(rows), 4)
        self.assertEqual(len({r['workload'] for r in rows}), 4)
        self.assertIn('4workers', rows[0]['workload'])
        self.assertTrue(any(r['workload'].startswith('matched_seq') for r in rows))

    def test_zero_reference_does_not_overwrite_previous_summary(self):
        original = b'preserve me'
        (self.folder / 'normalized.csv').write_bytes(original)
        write_csv(self.folder / 'summary.csv', [dict(profile='seq_read', block_bytes=1048576,
                  queue_depth=32, read_GiB_s_median=0)])
        result = self.run_summary()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('greater than zero', result.stderr)
        self.assertEqual((self.folder / 'normalized.csv').read_bytes(), original)

    def test_ambiguous_reference_is_rejected(self):
        row = dict(profile='seq_read', block_bytes=1048576, queue_depth=32, read_GiB_s_median=4)
        write_csv(self.folder / 'summary.csv', [row, row])
        self.assertNotEqual(self.run_summary().returncode, 0)
        self.assertFalse((self.folder / 'normalized.csv').exists())

    def test_incomplete_result_warns_outside_csv(self):
        (self.folder / 'environment.json').write_text(json.dumps({'status': 'interrupted'}))
        result = self.run_summary()
        self.assertEqual(result.returncode, 0)
        self.assertIn('WARNING', result.stderr)
        self.assertEqual(len(self.read_output()), 3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
