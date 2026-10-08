#!/bin/sh
# Standalone Linux direct-I/O benchmark. Only Python 3.8+ and fio are required.
set -eu
if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 (3.8 or newer) is required.' >&2
    exit 1
fi
exec python3 - "$@" <<'PY'
import argparse
import csv
import datetime as dt
import fcntl
import json
import mmap
import os
from pathlib import Path
import platform
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

VERSION = '1.0.0'
GIB = 1024 ** 3
MIB = 1024 ** 2


def size_bytes(value):
    match = re.fullmatch(r'([1-9][0-9]*)([kmgt]?)(?:i?b)?', value.lower())
    if not match:
        raise argparse.ArgumentTypeError('use a positive integer, optionally followed by K/M/G/T (binary units)')
    return int(match[1]) * 1024 ** ('kmgt'.find(match[2]) + 1 if match[2] else 0)


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError('must be at least 1')
    return value


def nonnegative(value):
    value = int(value)
    if value < 0:
        raise argparse.ArgumentTypeError('must be at least 0')
    return value


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def save_json(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def csv_cell(value):
    # Prevent a user-supplied label from becoming an Excel formula.
    if isinstance(value, str) and value.startswith(('=', '+', '-', '@', '\t', '\r')):
        return "'" + value
    return value


def write_csv(path, rows):
    if not rows:
        return
    tmp = path.with_suffix('.csv.tmp')
    with tmp.open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows({k: csv_cell(v) for k, v in row.items()} for row in rows)
    tmp.replace(path)


def capture(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def proc_io():
    return {k: int(v) for k, v in (line.split(':') for line in Path('/proc/self/io').read_text().splitlines())}


def direct_probe(path):
    """Two reads of the same range must both reach the Linux storage I/O path."""
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECT)
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        if not flags & os.O_DIRECT:
            raise RuntimeError('O_DIRECT missing: buffered fallback is forbidden')
        reads = []
        with mmap.mmap(-1, MIB) as buf:
            for _ in range(2):
                before = proc_io()['read_bytes']
                got = os.preadv(fd, [buf], 0)
                actual = proc_io()['read_bytes'] - before
                if got != MIB or actual < MIB:
                    raise RuntimeError('Cannot verify direct storage reads: got=%d, /proc read_bytes=%d. '
                                       'Use a local block-backed filesystem; RAM filesystems are not supported.' % (got, actual))
                reads.append({'requested_bytes': MIB, 'returned_bytes': got, 'process_read_bytes': actual})
        return {'fcntl_O_DIRECT': True, 'flags_octal': oct(flags), 'repeated_same_range_reads': reads,
                'scope': 'Bypasses Linux page cache; does not bypass drive/controller caches.'}
    finally:
        os.close(fd)


def inspect_direct_fd(pid, path):
    """fio uses thread=1, so job descriptors are visible in its process fd table."""
    root = Path('/proc') / str(pid)
    try:
        for entry in (root / 'fd').iterdir():
            try:
                if os.readlink(str(entry)) != str(path):
                    continue
                info = (root / 'fdinfo' / entry.name).read_text()
                match = re.search(r'^flags:\s*([0-7]+)', info, re.M)
                if match:
                    flags = int(match[1], 8)
                    if not flags & os.O_DIRECT:
                        raise RuntimeError('fio opened its data file WITHOUT O_DIRECT')
                    return {'fd': int(entry.name), 'flags_octal': oct(flags), 'O_DIRECT': True}
            except (FileNotFoundError, PermissionError):
                continue
    except (FileNotFoundError, PermissionError):
        pass
    return None


def environment(target, args, fio_version):
    mount_text = capture(['findmnt', '-J', '-T', str(target), '-o', 'SOURCE,FSTYPE,TARGET,MAJ:MIN,OPTIONS'])
    mounts = json.loads(mount_text).get('filesystems', []) if mount_text else []
    mount = mounts[0] if mounts else {}
    if mount.get('fstype') in ('tmpfs', 'ramfs', 'devtmpfs'):
        raise RuntimeError('RAM-backed filesystem rejected: ' + mount['fstype'])
    block_text = capture(['lsblk', '-J', '-b', '-o', 'NAME,TYPE,SIZE,ROTA,MODEL,TRAN,MOUNTPOINT'])
    cpu = ''
    for line in Path('/proc/cpuinfo').read_text().splitlines():
        if line.startswith('model name'):
            cpu = line.split(':', 1)[1].strip()
            break
    sensors = []
    device = Path('/sys/dev/block') / mount.get('maj:min', 'unknown')
    if device.exists():
        real = device.resolve()
        for node in [real] + list(real.parents):
            for sensor in node.glob('hwmon*/temp*_input'):
                sensors.append(sensor)
            for sensor in node.glob('hwmon/hwmon*/temp*_input'):
                sensors.append(sensor)
            for sensor in node.glob('device/hwmon/hwmon*/temp*_input'):
                sensors.append(sensor)
            if node == Path('/sys/devices'):
                break
    args_dict = vars(args).copy()
    result = {'tool_version': VERSION, 'created_utc': utc(), 'label': args.label,
              'os': platform.platform(), 'kernel': platform.release(), 'machine': platform.machine(),
              'cpu': cpu, 'logical_cpus': os.cpu_count(), 'python': platform.python_version(),
              'fio': fio_version, 'target': str(target), 'mount': mount,
              'lsblk': json.loads(block_text) if block_text else None,
              'memory': Path('/proc/meminfo').read_text().splitlines()[0],
              'free_bytes_before': shutil.disk_usage(target).free, 'arguments': args_dict,
              'temperature_sensor_paths': sorted(set(str(p) for p in sensors)),
              'cache_policy': 'O_DIRECT mandatory. No host page-cache fallback. Device cache remains enabled.',
              'status': 'preparing'}
    return result


def temperatures(env):
    result = {}
    for path in env['temperature_sensor_paths']:
        try:
            result[path] = int(Path(path).read_text().strip()) / 1000.0
        except (OSError, ValueError):
            pass
    return result


def cooling(env, args):
    if args.max_temp_c is None:
        return
    start = time.monotonic()
    announced = False
    while True:
        values = temperatures(env)
        if not values:
            raise RuntimeError('--max-temp-c requested, but no readable temperature sensor for the target device')
        if max(values.values()) <= args.max_temp_c:
            return
        if time.monotonic() - start > args.cool_timeout:
            raise RuntimeError('Temperature did not fall below the configured threshold before --cool-timeout')
        if not announced:
            print('Cooling: hottest device sensor %.1f C; waiting for <= %.1f C' %
                  (max(values.values()), args.max_temp_c), flush=True)
            announced = True
        time.sleep(2)


def run_fio(cmd, stem, out, data, env, timeout, require_fd):
    save_json(out / 'raw' / (stem + '.command.json'), cmd)
    observations = {'started_utc': utc(), 'temperature_start_c': temperatures(env), 'direct_fd': None}
    samples = list(observations['temperature_start_c'].values())
    with (out / 'raw' / (stem + '.log')).open('w') as log:
        process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        started = time.monotonic()
        next_temp = started
        try:
            while process.poll() is None:
                if observations['direct_fd'] is None:
                    observations['direct_fd'] = inspect_direct_fd(process.pid, data)
                now = time.monotonic()
                if now >= next_temp:
                    samples.extend(temperatures(env).values())
                    next_temp = now + 1
                if now - started > timeout:
                    raise RuntimeError('fio timed out: ' + stem)
                time.sleep(0.05 if observations['direct_fd'] is None else 0.2)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            observations['ended_utc'] = utc()
            observations['exit_code'] = process.returncode
            observations['wall_seconds'] = time.monotonic() - started
            observations['temperature_end_c'] = temperatures(env)
            samples.extend(observations['temperature_end_c'].values())
            observations['temperature_peak_c'] = max(samples) if samples else None
            save_json(out / 'raw' / (stem + '.audit.json'), observations)
    if process.returncode:
        raise RuntimeError('fio failed (%d), see raw/%s.log and raw/%s.json' % (process.returncode, stem, stem))
    if require_fd and observations['direct_fd'] is None:
        raise RuntimeError('Could not observe the fio O_DIRECT descriptor; refusing an unverified result: ' + stem)
    result = json.loads((out / 'raw' / (stem + '.json')).read_text())
    jobs = result.get('jobs', [])
    if len(jobs) != 1 or jobs[0].get('error', 0):
        raise RuntimeError('fio job error: ' + stem)
    options = dict(result.get('global options', {}))
    options.update(jobs[0].get('job options', {}))
    if str(options.get('direct')) != '1':
        raise RuntimeError('fio JSON does not confirm direct=1: ' + stem)
    return jobs[0], observations


def profiles(args):
    result = [{'profile': 'seq_read', 'rw': 'read', 'block_bytes': args.seq_bs, 'qd': args.seq_qd}]
    for bs in args.random_bs:
        for name, qd in [('random_read_low_qd', args.low_qd), ('random_read_high_qd', args.high_qd)]:
            result.append({'profile': name, 'rw': 'randread', 'block_bytes': bs, 'qd': qd})
    return result


def fio_base(fio, args, data):
    return [fio, '--filename=' + str(data), '--size=' + str(args.size), '--direct=1',
            '--ioengine=' + args.engine, '--thread=1', '--numjobs=1', '--group_reporting=1',
            '--invalidate=1', '--allow_file_create=0', '--output-format=json', '--eta=never']


def metric_row(args, profile, rep, job, audit):
    read = job['read']
    if read.get('io_bytes', 0) <= 0 or read.get('runtime', 0) <= 0:
        raise RuntimeError('fio returned no measured read I/O')
    clat = read.get('clat_ns')
    scale = 0.001
    if clat is None:
        clat = read.get('clat_us', {})
        scale = 1.0
    pct = {float(k): v for k, v in clat.get('percentile', {}).items()}
    if not all(p in pct for p in [50.0, 95.0, 99.0]):
        raise RuntimeError('fio completion-latency percentiles are missing')
    bw = read.get('bw_bytes', read.get('bw', 0) * 1024)
    depth = job.get('iodepth_level', {})
    row = {'label': args.label, 'profile': profile['profile'], 'block_bytes': profile['block_bytes'],
           'queue_depth': profile['qd'], 'jobs': 1, 'engine': args.engine, 'direct_io': 1,
           'file_size_bytes': args.size, 'runtime_requested_s': args.runtime, 'ramp_s': args.ramp,
           'repetition': rep, 'read_GiB_s': bw / GIB, 'read_MB_s': bw / 1e6,
           'read_IOPS': read['iops'], 'read_bytes': read['io_bytes'],
           'measured_runtime_s': read['runtime'] / 1000,
           'clat_mean_us': clat['mean'] * scale, 'clat_p50_us': pct[50.0] * scale,
           'clat_p95_us': pct[95.0] * scale, 'clat_p99_us': pct[99.0] * scale,
           'iodepth_1_pct': depth.get('1', 0), 'iodepth_2_pct': depth.get('2', 0),
           'iodepth_4_pct': depth.get('4', 0), 'iodepth_8_pct': depth.get('8', 0),
           'iodepth_16_pct': depth.get('16', 0), 'iodepth_32_pct': depth.get('32', 0),
           'iodepth_ge64_pct': depth.get('>=64', 0),
           'fio_fd_O_DIRECT_verified': int(bool(audit['direct_fd'])),
           'temperature_start_max_C': max(audit['temperature_start_c'].values(), default=''),
           'temperature_peak_C': audit['temperature_peak_c'] if audit['temperature_peak_c'] is not None else '',
           'started_utc': audit['started_utc']}
    return row


def summarize(rows):
    keys = sorted(set((r['profile'], r['block_bytes'], r['queue_depth']) for r in rows),
                  key=lambda k: (k[0] != 'seq_read', k[1], k[2]))
    result = []
    for key in keys:
        group = [r for r in rows if (r['profile'], r['block_bytes'], r['queue_depth']) == key]
        first = group[0]
        bw = [r['read_GiB_s'] for r in group]
        med = statistics.median(bw)
        result.append({'label': first['label'], 'profile': key[0], 'block_bytes': key[1],
                       'queue_depth': key[2], 'jobs': 1, 'engine': first['engine'], 'direct_io': 1,
                       'file_size_bytes': first['file_size_bytes'], 'runtime_requested_s': first['runtime_requested_s'],
                       'ramp_s': first['ramp_s'], 'repetitions_completed': len(group),
                       'read_GiB_s_median': med, 'read_GiB_s_min': min(bw), 'read_GiB_s_max': max(bw),
                       'read_GiB_s_stdev': statistics.stdev(bw) if len(bw) > 1 else '',
                       'read_MB_s_median': statistics.median(r['read_MB_s'] for r in group),
                       'read_IOPS_median': statistics.median(r['read_IOPS'] for r in group),
                       'clat_mean_us_median': statistics.median(r['clat_mean_us'] for r in group),
                       'clat_p50_us_median': statistics.median(r['clat_p50_us'] for r in group),
                       'clat_p99_us_median': statistics.median(r['clat_p99_us'] for r in group),
                       'fio_fd_O_DIRECT_verified_all': int(all(r['fio_fd_O_DIRECT_verified'] for r in group))})
    return result


def comparisons(summary):
    seqs = [r for r in summary if r['profile'] == 'seq_read']
    if not seqs:
        return []
    seq = seqs[0]
    result = []
    for low in summary:
        if low['profile'] != 'random_read_low_qd':
            continue
        high = next((r for r in summary if r['profile'] == 'random_read_high_qd' and
                     r['block_bytes'] == low['block_bytes']), None)
        if high is None:
            continue
        s, l, h = [r['read_GiB_s_median'] for r in [seq, low, high]]
        result.append({'label': low['label'], 'random_block_KiB': low['block_bytes'] / 1024,
                       'sequential_block_KiB': seq['block_bytes'] / 1024,
                       'sequential_QD': seq['queue_depth'], 'random_low_QD': low['queue_depth'],
                       'random_high_QD': high['queue_depth'], 'sequential_GiB_s': s,
                       'random_low_QD_GiB_s': l, 'random_high_QD_GiB_s': h,
                       'low_QD_vs_sequential_pct': 100 * l / s,
                       'high_QD_vs_sequential_pct': 100 * h / s, 'high_vs_low_QD_x': h / l,
                       'sequential_reps': seq['repetitions_completed'],
                       'low_QD_reps': low['repetitions_completed'], 'high_QD_reps': high['repetitions_completed']})
    return result


def write_tables(out, rows):
    write_csv(out / 'runs.csv', rows)
    summary = summarize(rows)
    write_csv(out / 'summary.csv', summary)
    write_csv(out / 'comparison.csv', comparisons(summary))
    return summary


def pattern_profiles():
    return [('gnn_feature_gather_4k', 4096), ('embedding_lookup_512b', 512), ('token_fetch_16k', 16384)]


def measure_pattern(args, name, useful_size, rep, data, env):
    """Actual synchronous reads + payload copy; synthetic AI access patterns, QD1."""
    block = max(4096, useful_size)
    rng = random.Random(args.seed + rep)
    # Bounded precomputed trace: offset generation is outside timed storage work.
    offsets = [rng.randrange(args.size // useful_size) * useful_size for _ in range(32768)]
    fd = os.open(str(data), os.O_RDONLY | os.O_DIRECT)
    try:
        if not fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_DIRECT:
            raise RuntimeError('Pattern workload O_DIRECT flag missing')
        with mmap.mmap(-1, block) as buf:
            def run_for(seconds):
                count, checksum, pos = 0, 0, 0
                start = time.perf_counter()
                deadline = start + seconds
                while time.perf_counter() < deadline:
                    logical = offsets[pos]
                    physical = logical // 4096 * 4096
                    if os.preadv(fd, [buf], physical) != block:
                        raise RuntimeError('Short direct pattern read')
                    payload = buf[logical - physical:logical - physical + useful_size]
                    checksum ^= payload[0]
                    count += 1
                    pos = (pos + 1) % len(offsets)
                return count, checksum, time.perf_counter() - start
            if args.ramp:
                run_for(args.ramp)
            start_temp = temperatures(env)
            before = proc_io()['read_bytes']
            started = utc()
            count, checksum, elapsed = run_for(args.runtime)
            actual = proc_io()['read_bytes'] - before
            end_temp = temperatures(env)
    finally:
        os.close(fd)
    if not count or actual < count * block:
        raise RuntimeError('Pattern physical read count is smaller than the requested direct I/O')
    return {'label': args.label, 'workload': name, 'kind': 'pattern_proxy', 'repetition': rep,
            'direct_io': 1, 'queue_depth': 1, 'engine': 'synchronous_preadv',
            'file_size_bytes': args.size, 'physical_request_bytes': block, 'useful_request_bytes': useful_size,
            'runtime_requested_s': args.runtime, 'ramp_s': args.ramp, 'measured_runtime_s': elapsed,
            'requests': count, 'physical_read_bytes': actual, 'useful_read_bytes': count * useful_size,
            'storage_GiB_s': actual / elapsed / GIB, 'useful_GiB_s': count * useful_size / elapsed / GIB,
            'requests_s': count / elapsed, 'io_amplification': actual / (count * useful_size),
            'fcntl_O_DIRECT_verified': 1, 'checksum': checksum,
            'temperature_start_max_C': max(start_temp.values(), default=''),
            'temperature_end_max_C': max(end_temp.values(), default=''), 'started_utc': started}


def workload_tables(out, work_rows, fio_rows):
    write_csv(out / 'workload_runs.csv', work_rows)
    refs = summarize(fio_rows)
    result = []
    for name in sorted(set(r['workload'] for r in work_rows)):
        group = [r for r in work_rows if r['workload'] == name]
        first = group[0]
        bw = [r['storage_GiB_s'] for r in group]
        physical = statistics.median(bw)
        useful = statistics.median(r['useful_GiB_s'] for r in group)
        seq = next((r for r in refs if r['profile'] == 'seq_read'), None)
        low = next((r for r in refs if r['profile'] == 'random_read_low_qd' and
                    r['block_bytes'] == first['physical_request_bytes']), None)
        high = next((r for r in refs if r['profile'] == 'random_read_high_qd' and
                     r['block_bytes'] == first['physical_request_bytes']), None)
        row = {'label': first['label'], 'workload': name, 'kind': first['kind'], 'direct_io': 1,
               'physical_request_bytes': first['physical_request_bytes'],
               'useful_request_bytes': first['useful_request_bytes'], 'workload_QD': 1,
               'file_size_bytes': first['file_size_bytes'], 'runtime_requested_s': first['runtime_requested_s'],
               'ramp_s': first['ramp_s'], 'repetitions_completed': len(group),
               'storage_GiB_s_median': physical, 'storage_GiB_s_min': min(bw), 'storage_GiB_s_max': max(bw),
               'useful_GiB_s_median': useful,
               'io_amplification_median': statistics.median(r['io_amplification'] for r in group),
               'random_comparison_scope': 'same request size; different engine and trace',
               'low_random_QD_matches_workload': int(low['queue_depth'] == 1) if low else ''}
        for key, ref in [('seq', seq), ('random_low_QD', low), ('random_high_QD', high)]:
            value = ref['read_GiB_s_median'] if ref else None
            row[key + '_block_bytes'] = ref['block_bytes'] if ref else ''
            row[key + '_queue_depth'] = ref['queue_depth'] if ref else ''
            row[key + '_GiB_s'] = value if value is not None else ''
            row['storage_vs_' + key + '_pct'] = 100 * physical / value if value else ''
            row['useful_vs_' + key + '_pct'] = 100 * useful / value if value else ''
        result.append(row)
    write_csv(out / 'workload_comparison.csv', result)
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog='bench.sh', description='Linux storage read benchmark with mandatory O_DIRECT. '
        'Creates and fully writes a NEW temporary file on the target filesystem, reads it, then deletes it. '
        'Requires Python 3.8+ and fio 3.x; does not require root.',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--target', default='.', help='existing directory on the storage to measure (never a raw device)')
    parser.add_argument('--output', help='NEW output directory; default: ./storage-results/<UTC>-<unique-id>')
    parser.add_argument('--label', default=platform.node(), help='environment label included in every CSV row')
    parser.add_argument('--size', type=size_bytes, default=8 * GIB, help='temporary data file size, e.g. 8G')
    parser.add_argument('--runtime', type=positive, default=10, help='measured seconds per fio run, excluding ramp')
    parser.add_argument('--ramp', type=nonnegative, default=2, help='warm-up seconds per run')
    parser.add_argument('--repeats', type=positive, default=3, help='repetitions of every profile')
    parser.add_argument('--seq-bs', type=size_bytes, default=MIB, help='sequential request size')
    parser.add_argument('--seq-qd', type=positive, default=32, help='sequential queue depth')
    parser.add_argument('--random-bs', default='4K,16K,128K,1M', help='comma-separated random request sizes')
    parser.add_argument('--low-qd', type=positive, default=1, help='low random queue depth')
    parser.add_argument('--high-qd', type=positive, default=128, help='high random queue depth')
    parser.add_argument('--engine', choices=['auto', 'libaio', 'io_uring'], default='auto', help='asynchronous fio engine')
    parser.add_argument('--fio', default='fio', help='fio executable name or path')
    parser.add_argument('--seed', type=nonnegative, default=20261008, help='reproducible profile order and random I/O seed')
    parser.add_argument('--pause', type=nonnegative, default=1, help='idle seconds between runs')
    parser.add_argument('--workloads', choices=['patterns', 'none'], default='patterns',
                        help='also measure three QD1 AI access-pattern proxies using direct preadv')
    parser.add_argument('--max-temp-c', type=float, help='wait before each run until all discovered target sensors are <= this value')
    parser.add_argument('--cool-timeout', type=positive, default=600, help='maximum temperature wait, seconds')
    args = parser.parse_args(argv)
    try:
        args.random_bs = sorted(set(size_bytes(x.strip()) for x in args.random_bs.split(',')))
    except argparse.ArgumentTypeError as e:
        parser.error('--random-bs: ' + str(e))
    if args.low_qd >= args.high_qd:
        parser.error('--low-qd must be less than --high-qd')
    if max(args.low_qd, args.high_qd, args.seq_qd) > 4096:
        parser.error('queue depths above 4096 are not supported')
    if args.size < 64 * MIB or args.size % MIB:
        parser.error('--size must be at least 64M and a multiple of 1M')
    for bs in [args.seq_bs] + args.random_bs:
        if bs < 4096 or bs % 4096 or args.size % bs:
            parser.error('request sizes must be multiples of 4K and divide --size exactly')
    if args.max_temp_c is not None and not (0 < args.max_temp_c < 150):
        parser.error('--max-temp-c must be between 0 and 150')
    return args


def main(argv=None):
    args = parse_args(argv)
    if platform.system() != 'Linux' or sys.version_info < (3, 8):
        raise RuntimeError('Linux and Python 3.8+ are required')
    target = Path(args.target).expanduser().resolve(strict=True)
    if not target.is_dir():
        raise RuntimeError('--target must be an existing directory, never a raw block device')
    # fio separates multiple filenames with a colon; refusing it prevents ambiguous targets.
    if ':' in str(target) or '\n' in str(target):
        raise RuntimeError('target paths containing colon or newline are not supported by this wrapper')
    fio = shutil.which(args.fio)
    version = capture([fio, '--version']) if fio else None
    if not version or not re.match(r'^fio-3\.', version):
        raise RuntimeError('fio 3.x is required (the Flexible I/O Tester, not Fiona). '
                           'Install using your OS package manager, e.g. apt install fio or dnf install fio.')
    engines = capture([fio, '--enghelp']) or ''
    if args.engine == 'auto':
        args.engine = next((e for e in ['libaio', 'io_uring'] if e in engines.split()), None)
    if not args.engine or args.engine not in engines.split():
        raise RuntimeError('fio needs an asynchronous libaio or io_uring engine; no synchronous fallback')
    if shutil.disk_usage(target).free < args.size + GIB:
        raise RuntimeError('Insufficient space: need --size plus 1 GiB of reserve on target')
    env = environment(target, args, version)
    if args.max_temp_c is not None and not temperatures(env):
        raise RuntimeError('No readable target temperature sensor for --max-temp-c')
    if args.output:
        out = Path(args.output).expanduser().resolve()
        out.mkdir(parents=True, exist_ok=False)
    else:
        parent = Path.cwd() / 'storage-results'
        parent.mkdir(exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ-')
        out = Path(tempfile.mkdtemp(prefix=stamp, dir=str(parent)))
    (out / 'raw').mkdir()
    env['output'] = str(out)
    save_json(out / 'environment.json', env)
    rows = []
    work_rows = []
    print('Output: %s\nTarget: %s\nFile: %.3f GiB; engine=%s; direct=1; jobs=1' %
          (out, target, args.size / GIB, args.engine), flush=True)
    work_count = len(pattern_profiles()) if args.workloads == 'patterns' else 0
    print('Profiles: %d fio + %d AI patterns, each x %d repetitions; %.1f min of read I/O + preparation/startup' %
          (len(profiles(args)), work_count, args.repeats,
           (len(profiles(args)) + work_count) * args.repeats * (args.runtime + args.ramp) / 60), flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix='.storage-io-bench-', dir=str(target)) as tmp:
            data = Path(tmp) / 'data.bin'
            # Only this newly created file can ever be written by the benchmark.
            fd = os.open(str(data), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            try:
                os.ftruncate(fd, args.size)
            finally:
                os.close(fd)
            base = fio_base(fio, args, data)
            cooling(env, args)
            print('Preparing a fully written data file (O_DIRECT + fsync)...', flush=True)
            prep_cmd = base + ['--name=prepare', '--rw=write', '--bs=1M', '--iodepth=32',
                               '--refill_buffers=1', '--scramble_buffers=1', '--end_fsync=1',
                               '--output=' + str(out / 'raw' / 'prepare.json')]
            job, _ = run_fio(prep_cmd, 'prepare', out, data, env, max(300, args.size / MIB * 2), False)
            if job['write']['io_bytes'] != args.size or data.stat().st_size != args.size:
                raise RuntimeError('Data file was not completely initialized')
            save_json(out / 'direct_io_validation.json', direct_probe(data))
            env['status'] = 'running'
            save_json(out / 'environment.json', env)
            for rep in range(1, args.repeats + 1):
                order = profiles(args)
                random.Random(args.seed + rep).shuffle(order)
                for profile in order:
                    if args.pause:
                        time.sleep(args.pause)
                    cooling(env, args)
                    stem = '%s_bs%d_qd%d_rep%d' % (profile['profile'], profile['block_bytes'], profile['qd'], rep)
                    print('[%d/%d] %s' % (len(rows) + 1, len(order) * args.repeats, stem), flush=True)
                    cmd = base + ['--name=' + stem, '--readonly', '--rw=' + profile['rw'],
                                  '--bs=' + str(profile['block_bytes']), '--iodepth=' + str(profile['qd']),
                                  '--time_based=1', '--runtime=' + str(args.runtime), '--ramp_time=' + str(args.ramp),
                                  '--randrepeat=1', '--randseed=' + str(args.seed + rep), '--norandommap=1',
                                  '--clat_percentiles=1', '--percentile_list=50:95:99:99.9',
                                  '--output=' + str(out / 'raw' / (stem + '.json'))]
                    job, audit = run_fio(cmd, stem, out, data, env, args.runtime + args.ramp + 120, True)
                    row = metric_row(args, profile, rep, job, audit)
                    rows.append(row)
                    write_tables(out, rows)
                    print('  %.3f GiB/s | %.0f IOPS | p99 %.1f us' %
                          (row['read_GiB_s'], row['read_IOPS'], row['clat_p99_us']), flush=True)
                if args.workloads == 'patterns':
                    work_order = pattern_profiles()
                    random.Random(args.seed + rep + 100).shuffle(work_order)
                    for name, useful_size in work_order:
                        if args.pause:
                            time.sleep(args.pause)
                        cooling(env, args)
                        print('[AI pattern] %s rep%d' % (name, rep), flush=True)
                        row = measure_pattern(args, name, useful_size, rep, data, env)
                        work_rows.append(row)
                        save_json(out / 'raw' / ('%s_rep%d.json' % (name, rep)), row)
                        workload_tables(out, work_rows, rows)
                        print('  storage %.3f GiB/s | useful %.3f GiB/s | amplification %.1fx' %
                              (row['storage_GiB_s'], row['useful_GiB_s'], row['io_amplification']), flush=True)
            env['status'] = 'complete'
    except BaseException as e:
        env['status'] = 'interrupted' if isinstance(e, KeyboardInterrupt) else 'failed'
        env['error'] = str(e) or type(e).__name__
        raise
    finally:
        env['finished_utc'] = utc()
        env['fio_runs_completed'] = len(rows)
        env['workload_runs_completed'] = len(work_rows)
        save_json(out / 'environment.json', env)
        write_tables(out, rows)
        workload_tables(out, work_rows, rows)
    summary = summarize(rows)
    print('\n%-26s %8s %5s %12s %12s %12s' % ('Profile', 'KiB', 'QD', 'GiB/s med', 'IOPS med', 'p99 us med'))
    for r in summary:
        print('%-26s %8g %5d %12.3f %12.0f %12.1f' %
              (r['profile'], r['block_bytes'] / 1024, r['queue_depth'], r['read_GiB_s_median'],
               r['read_IOPS_median'], r['clat_p99_us_median']))
    print('\nCSV comparison: %s\nCSV summary:    %s\nCSV per-run:    %s' %
          (out / 'comparison.csv', out / 'summary.csv', out / 'runs.csv'), flush=True)
    if work_rows:
        print('CSV workloads:  %s' % (out / 'workload_comparison.csv'), flush=True)
    return 0


def interrupted(signum, frame):
    raise KeyboardInterrupt('signal %d' % signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nInterrupted. Owned temporary data removed; completed results retained.', file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print('ERROR: ' + str(e), file=sys.stderr)
        sys.exit(1)
PY
