#!/usr/bin/env python3
"""Statistics/safety checks, plus opt-in real fio integration tests."""
import csv
import ctypes
import fcntl
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'bench.sh'
source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
bench = types.ModuleType('bench')
exec(compile(source, str(SCRIPT), 'exec'), bench.__dict__)
INTEGRATION = '--integration' in sys.argv
if INTEGRATION:
    sys.argv.remove('--integration')


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def row(name, bs, qd, bandwidth, rep):
    return {'label': 'test', 'profile': name, 'block_bytes': bs, 'queue_depth': qd,
            'jobs': 1, 'host_page_cache_bypass_verified': 1, 'engine': 'libaio', 'file_size_bytes': 2 ** 30, 'runtime_requested_s': 1, 'ramp_s': 0,
            'repetition': rep, 'read_GiB_s': bandwidth, 'read_MB_s': bandwidth * 2 ** 30 / 1e6,
            'read_IOPS': bandwidth * 2 ** 30 / bs, 'clat_mean_us': 100, 'clat_p50_us': 80,
            'clat_p99_us': 500, 'fio_fd_O_DIRECT_verified': 1}


class AnalysisTests(unittest.TestCase):
    def test_median_and_ratio_use_matching_request_size(self):
        rows = []
        for rep, speed in enumerate([1, 9, 2], 1):
            rows.extend([row('seq_read', 1048576, 32, speed * 10, rep),
                         row('random_read_low_qd', 4096, 1, speed, rep),
                         row('random_read_high_qd', 4096, 128, speed * 4, rep),
                         row('random_read_high_qd', 16384, 128, speed * 7, rep)])
        summary = bench.summarize(rows)
        result = bench.comparisons(summary)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['sequential_GiB_s'], 20)
        self.assertEqual(result[0]['random_low_QD_GiB_s'], 2)
        self.assertEqual(result[0]['random_high_QD_GiB_s'], 8)
        self.assertEqual(result[0]['low_QD_vs_sequential_pct'], 10)
        self.assertEqual(result[0]['high_vs_low_QD_x'], 4)
        low = next(r for r in summary if r['profile'] == 'random_read_low_qd')
        self.assertEqual(low['read_GiB_s_min'], 1)
        self.assertEqual(low['read_GiB_s_max'], 9)
        self.assertEqual(low['repetitions_completed'], 3)

    def test_incomplete_comparison_does_not_invent_baselines(self):
        rows = [row('seq_read', 1048576, 32, 6, 1), row('random_read_low_qd', 4096, 1, .1, 1)]
        self.assertEqual(bench.comparisons(bench.summarize(rows)), [])
        self.assertEqual(bench.summarize(rows)[0]['read_GiB_s_stdev'], '')

    def test_csv_label_escaping_and_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'out.csv'
            bench.write_csv(path, [{'label': '=1+1', 'description': 'comma, 한국어\nline', 'value': 1.5}])
            parsed = read_csv(path)
            self.assertEqual(parsed[0]['label'], "'=1+1")
            self.assertEqual(parsed[0]['description'], 'comma, 한국어\nline')
            self.assertEqual(float(parsed[0]['value']), 1.5)

    def test_invalid_geometry_rejected_before_io(self):
        for argv in [['--low-qd', '128'], ['--random-bs', '512'], ['--size', '1M'],
                     ['--seq-bs', '12K'], ['--runtime', '0'], ['--random-bs', 'invalid']]:
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                bench.parse_args(argv)

    @unittest.skipUnless(bench.SYSTEM == 'Linux', 'Linux descriptor audit')
    def test_buffered_file_descriptor_is_rejected(self):
        with tempfile.NamedTemporaryFile() as f:
            with self.assertRaisesRegex(RuntimeError, 'WITHOUT O_DIRECT'):
                bench.inspect_direct_fd(os.getpid(), Path(f.name))

    @unittest.skipUnless(bench.SYSTEM == 'Darwin', 'Darwin descriptor audit')
    def test_macos_cache_flag_is_observed_and_buffered_fd_not_accepted(self):
        with tempfile.NamedTemporaryFile() as f:
            path = Path(f.name).resolve()
            self.assertIsNone(bench.inspect_direct_fd(os.getpid(), path))
            fcntl.fcntl(f.fileno(), bench.F_NOCACHE, 1)
            self.assertTrue(fcntl.fcntl(f.fileno(), fcntl.F_GETFL) & bench.FNOCACHE)
            self.assertTrue(bench.inspect_direct_fd(os.getpid(), path)['F_NOCACHE'])
            fcntl.fcntl(f.fileno(), bench.F_NOCACHE, 0)
            self.assertIsNone(bench.inspect_direct_fd(os.getpid(), path))

    def test_macos_rusage_abi(self):
        self.assertEqual(ctypes.sizeof(bench.DarwinIO.RusageV2), 160)
        self.assertEqual(bench.DarwinIO.RusageV2.read_bytes.offset, 144)
        self.assertEqual(bench.DarwinIO.RusageV2.write_bytes.offset, 152)

    def test_capped_queue_is_not_reported_as_achieved(self):
        state, pct = bench.depth_assessment(128, {'16': 98, '>=64': 2})
        self.assertEqual(state, 'below_requested_depth_bucket')
        state, pct = bench.depth_assessment(128, {'>=64': 99.9})
        self.assertEqual(state, 'observed_ge64_exact_depth_unknown')
        self.assertEqual(bench.depth_assessment(1, {'1': 100})[0], 'QD1')

    def test_missing_workload_reference_is_blank(self):
        work = {'label': 'test', 'workload': 'embedding', 'kind': 'pattern_proxy',
                'physical_request_bytes': 4096, 'useful_request_bytes': 512,
                'queue_depth': 1, 'jobs': 1, 'engine': 'libaio',
                'file_size_bytes': 2 ** 30, 'runtime_requested_s': 1, 'ramp_s': 0,
                'storage_GiB_s': .08, 'useful_GiB_s': .01, 'io_amplification': 8}
        refs = [row('seq_read', 1048576, 32, 4, 1), row('random_read_low_qd', 16384, 1, .2, 1)]
        with tempfile.TemporaryDirectory() as d:
            result = bench.workload_tables(Path(d), [work], refs)[0]
            self.assertEqual(result['storage_vs_seq_pct'], 2)
            self.assertEqual(result['useful_vs_seq_pct'], .25)
            self.assertEqual(result['random_low_QD_GiB_s'], '')
            self.assertEqual(result['storage_vs_random_low_QD_pct'], '')

    def test_matched_pairs_and_worker_file_regions(self):
        args = bench.parse_args(['--engine', 'libaio', '--high-jobs', '4', '--high-qd', '32', '--matched-seq'])
        profiles = bench.profiles(args)
        self.assertEqual(len(profiles), 17)
        for p in [p for p in profiles if p['rw'] == 'randread']:
            matched = next(r for r in profiles if r['profile'] == p['profile'].replace('random_read', 'matched_seq')
                           and r['block_bytes'] == p['block_bytes'])
            self.assertEqual((p['qd'], p['jobs']), (matched['qd'], matched['jobs']))
        high = next(p for p in profiles if p['profile'] == 'random_read_high_qd')
        cmd = bench.measurement_command([], args, high, 1, Path('test.json'), 'test')
        self.assertIn('--numjobs=4', cmd)
        self.assertIn('--offset_increment=' + str(args.size // 4), cmd)
        self.assertIn('--size=' + str(args.size // 4), cmd)
        self.assertIn('--lat_percentiles=1', cmd)

    def test_macos_profiles_use_workers_instead_of_async_qd(self):
        with patch.object(bench, 'SYSTEM', 'Darwin'):
            args = bench.parse_args(['--engine', 'psync'])
        profiles = bench.profiles(args) + bench.pattern_profiles(args)
        self.assertTrue(all(p['qd'] == 1 for p in profiles))
        self.assertEqual(next(p['jobs'] for p in profiles if p['profile'] == 'random_read_high_qd'), 4)
        self.assertIn('parallel_uniform_4k', [p['profile'] for p in profiles])

    def test_total_latency_and_cpu_pressure_are_not_hidden(self):
        latency = lambda mean: {'mean': mean, 'percentile': {'50.000000': mean, '95.000000': mean * 2,
                            '99.000000': mean * 3, '99.900000': mean * 4}}
        read = {'io_bytes': 409600, 'runtime': 1000, 'bw_bytes': 409600, 'iops': 100,
                'lat_ns': latency(26400), 'clat_ns': latency(13700), 'slat_ns': {'mean': 12700}}
        args = bench.parse_args(['--engine', 'libaio'])
        job = {'read': read, 'usr_cpu': 10.2, 'sys_cpu': 85, 'iodepth_level': {'16': 98, '>=64': 2}}
        audit = {'direct_fd': {'verified': True}, 'host_block_read_coverage_verified': True,
                 'host_block_read_bytes': 409600, 'temperature_start_c': {}, 'temperature_peak_c': None, 'started_utc': ''}
        profile = next(p for p in bench.profiles(args) if p['profile'] == 'random_read_high_qd')
        actual = bench.metric_row(args, profile, 1, job, audit)
        self.assertAlmostEqual(actual['lat_mean_us'], 26.4)
        self.assertAlmostEqual(actual['slat_mean_us'], 12.7)
        self.assertAlmostEqual(actual['lat_p99_9_us'], 105.6)
        self.assertIn('host_cpu_pressure_possible', actual['warnings'])
        self.assertIn('below_requested_depth_bucket', actual['warnings'])
        self.assertEqual(actual['media_cache_bypass_verified'], 0)
        read['slat_ns'] = {'N': 0, 'mean': 0}
        self.assertEqual(bench.latency_metrics(read)['slat_mean_us'], '')

    def test_storage_chain_finds_partition_parent_and_rejects_dm(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sysdev = root / 'dev'; sysdev.mkdir()
            disk = root / 'nvme0n1'; disk.mkdir()
            (disk / 'stat').write_text('1 0 8 0')
            part = disk / 'nvme0n1p1'; part.mkdir(); (part / 'partition').write_text('1')
            dev = root.stat().st_dev
            link = sysdev / ('%d:%d' % (os.major(dev), os.minor(dev)))
            link.symlink_to(part, target_is_directory=True)
            found = bench.linux_storage_path(root, sysdev)
            self.assertEqual(list(found['leaf_stat_paths']), ['nvme0n1'])
            self.assertEqual(bench.block_reads({'storage_path': found}), {'nvme0n1': 4096})
            link.unlink()
            dm = root / 'dm-0'; (dm / 'slaves').mkdir(parents=True)
            (dm / 'slaves' / 'nvme0n1p1').symlink_to(part, target_is_directory=True)
            link.symlink_to(dm, target_is_directory=True)
            found = bench.linux_storage_path(root, sysdev)
            self.assertEqual(found['rejected_layers'], ['dm-0'])
            self.assertEqual(list(found['leaf_stat_paths']), ['nvme0n1'])



@unittest.skipUnless(INTEGRATION, 'pass --integration to exercise a real local filesystem and fio')
class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bench-integration-', dir=str(ROOT))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / 'target with spaces'
        self.target.mkdir()
        self.sentinel = self.target / 'existing-user-file.txt'
        self.sentinel.write_text('do not touch')
        self.out = self.root / 'results'
        self.cmd = ['sh', str(SCRIPT), '--target', str(self.target), '--output', str(self.out),
                    '--size', '128M', '--runtime', '1', '--ramp', '0', '--repeats', '2', '--pause', '0',
                    '--label', 'test,한국어']

    def assert_clean(self):
        self.assertEqual(self.sentinel.read_text(), 'do not touch')
        self.assertEqual(list(self.target.iterdir()), [self.sentinel])

    def test_real_direct_io_and_all_csvs(self):
        result = subprocess.run(self.cmd, capture_output=True, text=True, timeout=150)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        env = json.loads((self.out / 'environment.json').read_text())
        self.assertEqual(env['status'], 'complete')
        runs = read_csv(self.out / 'runs.csv')
        self.assertEqual(len(runs), 18)
        self.assertTrue(all(r['host_page_cache_bypass_verified'] == '1' for r in runs))
        native_field = 'fio_fd_F_NOCACHE_verified' if bench.SYSTEM == 'Darwin' else 'fio_fd_O_DIRECT_verified'
        self.assertTrue(all(r[native_field] == '1' for r in runs))
        self.assertTrue(all(r['cache_mode'] == bench.CACHE_MODE for r in runs))
        if bench.SYSTEM == 'Darwin':
            self.assertTrue(all(r['engine'] == 'psync' for r in runs))
            self.assertTrue(all(r['fio_fd_O_DIRECT_verified'] == '' for r in runs))
        self.assertTrue(all(float(r['read_GiB_s']) > 0 for r in runs))
        self.assertTrue(all(r['label'] == 'test,한국어' for r in runs))
        summary = read_csv(self.out / 'summary.csv')
        self.assertEqual(len(summary), 9)
        self.assertTrue(all(r['repetitions_completed'] == '2' for r in summary))
        self.assertEqual(len(read_csv(self.out / 'comparison.csv')), 4)
        work = read_csv(self.out / 'workload_comparison.csv')
        self.assertEqual(len(work), 3)
        self.assertEqual({r['workload'] for r in work}, {'zipf_read_4k', 'contiguous_run_16k',
                         'parallel_uniform_4k' if bench.SYSTEM == 'Darwin' else 'batched_uniform_4k'})
        self.assertTrue(all(r['storage_GiB_s_median'] == r['useful_GiB_s_median'] for r in work))
        patterns = read_csv(self.out / 'workload_runs.csv')
        for r in runs + patterns:
            self.assertGreaterEqual(float(r['lat_mean_us']), float(r['clat_mean_us']))
            self.assertGreater(float(r['lat_p99_9_us']), 0)
            self.assertEqual(r['media_cache_bypass_verified'], '0')
            if bench.SYSTEM == 'Linux':
                self.assertEqual(r['host_block_read_coverage_verified'], '1')
        # All profiles use fio and participate in one shuffled schedule.
        commands = sorted((self.out / 'raw').glob('*.command.json'))
        self.assertEqual(len(commands), 25)
        epochs = sorted(r['started_utc'] for r in patterns)
        self.assertTrue(any(r['started_utc'] > epochs[0] for r in runs))
        probe = json.loads((self.out / 'direct_io_validation.json').read_text())
        self.assertEqual(probe['cache_mode'], bench.CACHE_MODE)
        for attempt in probe['repeated_same_range_reads']:
            self.assertGreaterEqual(attempt['process_read_bytes'], attempt['requested_bytes'])
        self.assert_clean()
        again = subprocess.run(self.cmd, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(len(read_csv(self.out / 'runs.csv')), 18)
        self.assert_clean()

    def test_sigterm_stops_fio_and_removes_only_owned_data(self):
        cmd = self.cmd + ['--runtime', '20', '--repeats', '1', '--workloads', 'none']
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for line in process.stdout:
                if line.startswith('[1/'):
                    time.sleep(.5)
                    process.send_signal(signal.SIGTERM)
                    break
            output, _ = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 130, output)
            self.assertEqual(json.loads((self.out / 'environment.json').read_text())['status'], 'interrupted')
            self.assert_clean()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=20)

    def test_multiple_workers_and_matched_sequential_references(self):
        cmd = self.cmd + ['--repeats', '1', '--random-bs', '4K', '--workloads', 'none',
                          '--high-jobs', '4', '--high-qd', '32', '--matched-seq']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = read_csv(self.out / 'matched_random_comparison.csv')
        self.assertEqual(len(rows), 2)
        self.assertEqual({r['jobs'] for r in rows}, {'1', '4'})
        for r in rows:
            self.assertAlmostEqual(float(r['random_to_matched_seq']),
                                   float(r['random_GiB_s']) / float(r['sequential_GiB_s']))
        self.assert_clean()

    def test_ram_filesystem_fails_closed(self):
        if bench.SYSTEM != 'Linux' or not Path('/dev/shm').is_dir():
            self.skipTest('no /dev/shm')
        result = subprocess.run(self.cmd + ['--target', '/dev/shm'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())
        self.assert_clean()


if __name__ == '__main__':
    unittest.main(verbosity=2)
