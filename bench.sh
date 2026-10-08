#!/bin/sh
# Standalone Linux/macOS uncached-I/O benchmark. Python 3.8+ and fio required.
set -eu
if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 (3.8 or newer) is required.' >&2
    exit 1
fi
exec python3 - "$@" <<'PY'
import argparse
import csv
import ctypes
import datetime as dt
import fcntl
import json
import mmap
import os
from pathlib import Path
import platform
import plistlib
import random
import re
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import time

VERSION = '2.0.0'
GIB = 1024 ** 3
MIB = 1024 ** 2
SYSTEM = platform.system()
CACHE_MODE = 'F_NOCACHE' if SYSTEM == 'Darwin' else 'O_DIRECT'
# Darwin ABI constants from Apple's xnu bsd/sys/{fcntl,proc_info,resource}.h.
F_NOCACHE = 48
FNOCACHE = 0x00040000
MAC = None


class DarwinIO:
    class RusageV2(ctypes.Structure):
        _fields_ = [('uuid', ctypes.c_ubyte * 16), ('prefix', ctypes.c_uint64 * 16),
                    ('read_bytes', ctypes.c_uint64), ('write_bytes', ctypes.c_uint64)]

    def __init__(self):
        self.libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.libproc.proc_pid_rusage.restype = ctypes.c_int
        self.libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                             ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_pidinfo.restype = ctypes.c_int
        self.libproc.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                               ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_pidfdinfo.restype = ctypes.c_int
        self.libc.pread.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int64]
        self.libc.pread.restype = ctypes.c_ssize_t

    def io(self):
        info = self.RusageV2()
        if self.libproc.proc_pid_rusage(os.getpid(), 2, ctypes.byref(info)) != 0:
            raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed; cannot verify storage reads')
        return {'read_bytes': info.read_bytes, 'write_bytes': info.write_bytes}

    def read_into(self, fd, buf, offset):
        pointer = ctypes.addressof(ctypes.c_char.from_buffer(buf))
        got = self.libc.pread(fd, pointer, len(buf), offset)
        if got < 0:
            raise OSError(ctypes.get_errno(), 'uncached pread failed')
        return got

    def inspect_fd(self, pid, path):
        # proc_fdinfo = int32 descriptor + uint32 type. Grow for concurrent opens.
        size = self.libproc.proc_pidinfo(pid, 1, 0, None, 0)
        if size <= 0:
            return None
        listing = ctypes.create_string_buffer(size + 4096)
        got = self.libproc.proc_pidinfo(pid, 1, 0, listing, len(listing))
        for offset in range(0, max(0, got) // 8 * 8, 8):
            fd, kind = struct.unpack_from('=iI', listing.raw, offset)
            if kind != 1:  # PROX_FDTYPE_VNODE
                continue
            info = ctypes.create_string_buffer(4096)
            count = self.libproc.proc_pidfdinfo(pid, fd, 2, info, len(info))
            # vnode_fdinfowithpath starts with fi_openflags and ends in char[1024].
            if count < 1048 or count > len(info):
                continue
            name = os.fsdecode(info.raw[count - 1024:count].split(b'\0', 1)[0])
            if name != str(path):
                continue
            flags = struct.unpack_from('=I', info.raw)[0]
            if flags & FNOCACHE:
                return {'fd': fd, 'flags_hex': hex(flags), 'F_NOCACHE': True,
                        'method': 'proc_pidfdinfo(FNOCACHE)'}
            # open() precedes fcntl(F_NOCACHE); only accept a verified later sample.
        return None


def darwin_io():
    global MAC
    if MAC is None:
        MAC = DarwinIO()
    return MAC


def open_uncached(path):
    fd = os.open(str(path), os.O_RDONLY | (os.O_DIRECT if SYSTEM == 'Linux' else 0))
    try:
        if SYSTEM == 'Darwin':
            fcntl.fcntl(fd, F_NOCACHE, 1)
        bit = FNOCACHE if SYSTEM == 'Darwin' else os.O_DIRECT
        if not fcntl.fcntl(fd, fcntl.F_GETFL) & bit:
            raise RuntimeError(CACHE_MODE + ' flag missing: buffered fallback is forbidden')
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_into(fd, buf, offset):
    if SYSTEM == 'Darwin':
        return darwin_io().read_into(fd, buf, offset)
    return os.preadv(fd, [buf], offset)


def cache_columns(verified=False):
    return {'os_family': SYSTEM, 'cache_mode': CACHE_MODE,
            'host_page_cache_bypass_verified': int(verified),
            'media_cache_bypass_verified': 0}


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
    if SYSTEM == 'Darwin':
        return darwin_io().io()
    return {k: int(v) for k, v in (line.split(':') for line in Path('/proc/self/io').read_text().splitlines())}


def direct_probe(path):
    """Two reads of the same range must both be accounted as process disk I/O."""
    fd = open_uncached(path)
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        reads = []
        with mmap.mmap(-1, MIB) as buf:
            for _ in range(2):
                before = proc_io()['read_bytes']
                got = read_into(fd, buf, 0)
                actual = proc_io()['read_bytes'] - before
                if got != MIB or actual < MIB:
                    raise RuntimeError('Cannot verify uncached storage reads: got=%d, process disk read_bytes=%d. '
                                       'Use a local block-backed filesystem; RAM filesystems are not supported.' % (got, actual))
                reads.append({'requested_bytes': MIB, 'returned_bytes': got, 'process_read_bytes': actual})
        return {**cache_columns(True), 'fcntl_O_DIRECT': SYSTEM == 'Linux',
                'fcntl_F_NOCACHE': SYSTEM == 'Darwin', 'flags_octal': oct(flags),
                'counter_source': 'proc_pid_rusage(RUSAGE_INFO_V2)' if SYSTEM == 'Darwin' else '/proc/self/io',
                'repeated_same_range_reads': reads,
                'scope': 'Bypasses host file-data cache; does not bypass drive/controller caches.'}
    finally:
        os.close(fd)


def inspect_direct_fd(pid, path):
    """fio uses thread=1, so job descriptors are visible in its process fd table."""
    if SYSTEM == 'Darwin':
        return darwin_io().inspect_fd(pid, path)
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


def read_optional(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def linux_storage_path(target, sys_dev_block=Path('/sys/dev/block')):
    dev = target.stat().st_dev
    start = sys_dev_block / ('%d:%d' % (os.major(dev), os.minor(dev)))
    nodes, leaves, rejected = {}, {}, []
    def visit(path):
        path = path.resolve()
        if path.name in nodes:
            return
        name = path.name
        nodes[name] = str(path)
        if name.startswith(('loop', 'zram', 'dm-', 'bcache')):
            rejected.append(name)
        if (path / 'partition').exists():
            visit(path.parent)
            return
        children = list((path / 'slaves').glob('*'))
        if children:
            for child in children:
                visit(child)
        elif (path / 'stat').exists():
            leaves[name] = str(path / 'stat')
    if start.exists():
        visit(start)
    return {'nodes': nodes, 'leaf_stat_paths': leaves, 'rejected_layers': sorted(rejected),
            'scope': 'host-visible whole-disk counters; includes other processes and warm-up; '
                     'does not prove NAND access or bypass of host/hypervisor/controller/drive caches'}


def block_reads(env):
    values = {}
    for name, path in env.get('storage_path', {}).get('leaf_stat_paths', {}).items():
        data = read_optional(path)
        if data is None:
            raise RuntimeError('Cannot read whole-disk statistics: ' + path)
        values[name] = int(data.split()[2]) * 512
    return values


def environment(target, args, fio_version):
    if SYSTEM == 'Darwin':
        # df resolves firmlinks and paths inside APFS volumes to their device.
        listing = capture(['df', '-P', str(target)])
        device = listing.splitlines()[-1].split()[0] if listing else ''
        if not device.startswith('/dev/disk'):
            raise RuntimeError('macOS target must be a local disk-backed volume')
        result = subprocess.run(['diskutil', 'info', '-plist', device], capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError('diskutil could not identify the target volume')
        disk = plistlib.loads(result.stdout)
        if disk.get('VirtualOrPhysical') == 'Virtual' and 'disk image' in str(disk).lower():
            raise RuntimeError('Disk-image targets are not supported for device measurements')
        return {'tool_version': VERSION, 'created_utc': utc(), 'label': args.label,
                'os': platform.platform(), 'kernel': platform.release(), 'machine': platform.machine(),
                'cpu': capture(['sysctl', '-n', 'machdep.cpu.brand_string']) or platform.processor(),
                'logical_cpus': os.cpu_count(), 'python': platform.python_version(), 'fio': fio_version,
                'target': str(target), 'mount': {k: disk.get(k) for k in
                ['DeviceIdentifier', 'DeviceNode', 'MountPoint', 'FilesystemType', 'FilesystemName',
                 'SolidState', 'BusProtocol', 'Internal', 'VirtualOrPhysical']},
                'memory_bytes': capture(['sysctl', '-n', 'hw.memsize']),
                'aio_limits': {k: capture(['sysctl', '-n', k]) for k in
                               ['kern.aiomax', 'kern.aioprocmax', 'kern.aiothreads']},
                'free_bytes_before': shutil.disk_usage(target).free, 'arguments': vars(args).copy(),
                'temperature_sensor_paths': [], 'storage_path': {'scope': 'macOS process disk I/O; media cache bypass unverified'},
                'high_concurrency_scope': 'psync worker concurrency, not Linux async or device queue depth',
                'cache_policy': 'F_NOCACHE mandatory. No host data-cache fallback. Device cache remains enabled.',
                'status': 'preparing'}
    mount_text = capture(['findmnt', '-J', '-T', str(target), '-o', 'SOURCE,FSTYPE,TARGET,MAJ:MIN,OPTIONS'])
    mounts = json.loads(mount_text).get('filesystems', []) if mount_text else []
    mount = mounts[0] if mounts else {}
    if mount.get('fstype') in ('tmpfs', 'ramfs', 'devtmpfs'):
        raise RuntimeError('RAM-backed filesystem rejected: ' + mount['fstype'])
    storage = linux_storage_path(target)
    if (storage['rejected_layers'] or not storage['leaf_stat_paths']) and not args.allow_indirect:
        raise RuntimeError('Unsupported or unresolved storage stack: %s. '
                           '--allow-indirect records a host-path measurement only.' % storage)
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
              'storage_path': storage,
              'virtualization': capture(['systemd-detect-virt']) or 'unknown_or_none',
              'power_and_queue': {
                  'cpu_governors': {p.parent.parent.name: read_optional(p) for p in Path('/sys/devices/system/cpu').glob('cpu[0-9]*/cpufreq/scaling_governor')},
                  'cpuidle_driver': read_optional('/sys/devices/system/cpu/cpuidle/current_driver'),
                  'cpu0_cstates': {p.name: {'name': read_optional(p/'name'), 'disabled': read_optional(p/'disable')}
                                  for p in Path('/sys/devices/system/cpu/cpu0/cpuidle').glob('state*')},
                  'nvme_apst_default_latency_us': read_optional('/sys/module/nvme_core/parameters/default_ps_max_latency_us'),
                  'max_sectors_kb': {name: read_optional(Path(path).parent/'queue/max_sectors_kb')
                                     for name, path in storage['leaf_stat_paths'].items()}},
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
    observations['block_read_bytes_before'] = block_reads(env)
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
            observations['block_read_bytes_after'] = block_reads(env)
            save_json(out / 'raw' / (stem + '.audit.json'), observations)
    if process.returncode:
        raise RuntimeError('fio failed (%d), see raw/%s.log and raw/%s.json' % (process.returncode, stem, stem))
    if require_fd and observations['direct_fd'] is None:
        raise RuntimeError('Could not observe the fio ' + CACHE_MODE + ' descriptor; refusing an unverified result: ' + stem)
    result = json.loads((out / 'raw' / (stem + '.json')).read_text())
    jobs = result.get('jobs', [])
    if len(jobs) != 1 or jobs[0].get('error', 0):
        raise RuntimeError('fio job error: ' + stem)
    options = dict(result.get('global options', {}))
    options.update(jobs[0].get('job options', {}))
    if str(options.get('direct')) != '1':
        raise RuntimeError('fio JSON does not confirm direct=1: ' + stem)
    before, after = observations['block_read_bytes_before'], observations['block_read_bytes_after']
    delta = sum(after[k] - v for k, v in before.items()) if before else None
    if before and any(after[k] < v for k, v in before.items()):
        raise RuntimeError('Device counters reset during fio run: ' + stem)
    expected = jobs[0]['read'].get('io_bytes', 0)
    observations['host_block_read_bytes'] = delta
    observations['fio_measured_read_bytes'] = expected
    observations['host_block_read_coverage_verified'] = bool(expected and delta is not None and delta >= expected)
    observations['media_cache_bypass_verified'] = False
    save_json(out / 'raw' / (stem + '.audit.json'), observations)
    if expected and delta is not None and delta < expected:
        raise RuntimeError('Host-visible whole-disk read bytes are below fio bytes: %d < %d' % (delta, expected))
    return jobs[0], observations


def profiles(args):
    def profile(name, rw, bs, qd, jobs=1):
        return dict(profile=name, rw=rw, block_bytes=bs, qd=1 if args.engine == 'psync' else qd,
                    jobs=jobs, kind='baseline', extra=[])
    result = [profile('seq_read', 'read', args.seq_bs, args.seq_qd, args.seq_jobs)]
    for bs in args.random_bs:
        for name, qd, jobs in [('random_read_low_qd', args.low_qd, 1), ('random_read_high_qd', args.high_qd, args.high_jobs)]:
            p = profile(name, 'randread', bs, qd, jobs)
            p['extra'] = ['--random_generator=lfsr', '--norandommap=1']
            result.append(p)
            if args.matched_seq:
                result.append(profile(name.replace('random_read', 'matched_seq'), 'read', bs, qd, jobs))
    return result


def pattern_profiles(args):
    depth = args.batch_qd
    common = {'kind': 'pattern_proxy', 'jobs': 1}
    result = [dict(common, profile='zipf_read_4k', rw='randread', block_bytes=4096, qd=1,
                   extra=['--random_distribution=zipf:' + str(args.zipf_theta), '--norandommap=1']),
              dict(common, profile='contiguous_run_16k', rw='randread:64', block_bytes=16384, qd=1,
                   extra=['--rw_sequencer=sequential', '--random_generator=lfsr', '--norandommap=1'])]
    if args.engine == 'psync':
        result.append(dict(common, profile='parallel_uniform_4k', rw='randread', block_bytes=4096,
                           qd=1, jobs=args.high_jobs, extra=['--random_generator=lfsr', '--norandommap=1']))
    else:
        result.append(dict(common, profile='batched_uniform_4k', rw='randread', block_bytes=4096,
                           qd=depth, extra=['--random_generator=lfsr', '--norandommap=1',
                           '--iodepth_batch_submit=' + str(depth), '--iodepth_batch_complete_min=' + str(depth),
                           '--iodepth_batch_complete_max=' + str(depth)]))
    return result


def fio_base(fio, args, data):
    return [fio, '--filename=' + str(data), '--size=' + str(args.size), '--direct=1',
            '--ioengine=' + args.engine, '--thread=1', '--numjobs=1', '--group_reporting=1',
            '--invalidate=1', '--allow_file_create=0', '--output-format=json', '--eta=never']


def measurement_command(base, args, profile, rep, output, name):
    region = args.size // profile['jobs']
    cmd = base + ['--name=' + name, '--readonly', '--rw=' + profile['rw'],
                  '--bs=' + str(profile['block_bytes']), '--iodepth=' + str(profile['qd']),
                  '--numjobs=' + str(profile['jobs']), '--filesize=' + str(args.size),
                  '--size=' + str(region), '--offset_increment=' + str(region),
                  '--time_based=1', '--runtime=' + str(args.runtime), '--ramp_time=' + str(args.ramp),
                  '--randrepeat=1', '--randseed=' + str(args.seed + rep),
                  '--clat_percentiles=1', '--lat_percentiles=1', '--percentile_list=50:95:99:99.9',
                  '--output=' + str(output)] + profile['extra']
    if args.uring_tuned:
        cmd += ['--fixedbufs=1', '--registerfiles=1']
    if args.hipri:
        cmd += ['--hipri=1']
    return cmd


def depth_assessment(qd, depth):
    bucket = max(n for n in [1, 2, 4, 8, 16, 32, 64] if n <= qd)
    key = '>=64' if bucket == 64 else str(bucket)
    pct = depth.get(key, 0)
    if qd == 1:
        return 'QD1', pct
    if pct < 90.0:
        return 'below_requested_depth_bucket', pct
    return ('observed_ge64_exact_depth_unknown' if qd >= 64 else 'requested_depth_bucket_observed'), pct


def latency_metrics(read):
    result = {}
    for name in ['slat', 'clat', 'lat']:
        values = read.get(name + '_ns')
        scale = .001
        if values is None:
            values, scale = read.get(name + '_us', {}), 1.0
        if values.get('N') == 0:
            values = {}
        result[name + '_mean_us'] = values['mean'] * scale if 'mean' in values else ''
        if name == 'slat':
            continue
        percentiles = {float(k): v for k, v in values.get('percentile', {}).items()}
        for pct, label in [(50, '50'), (95, '95'), (99, '99'), (99.9, '99_9')]:
            if pct not in percentiles:
                raise RuntimeError('fio %s latency percentile %s is missing' % (name, label))
            result[name + '_p' + label + '_us'] = percentiles[pct] * scale
    return result


def metric_row(args, profile, rep, job, audit):
    read = job['read']
    if read.get('io_bytes', 0) <= 0 or read.get('runtime', 0) <= 0:
        raise RuntimeError('fio returned no measured read I/O')
    bw = read.get('bw_bytes', read.get('bw', 0) * 1024)
    depth = job.get('iodepth_level', {})
    depth_status, depth_pct = depth_assessment(profile['qd'], depth)
    if args.engine == 'psync' and profile['jobs'] > 1:
        depth_status = 'sync_worker_concurrency_not_device_qd'
    cpu = job.get('usr_cpu', 0) + job.get('sys_cpu', 0)
    warnings = []
    if cpu >= 90:
        warnings.append('host_cpu_pressure_possible')
    if depth_status == 'below_requested_depth_bucket':
        warnings.append(depth_status)
    row = {'label': args.label, 'profile': profile['profile'], 'kind': profile['kind'],
           'block_bytes': profile['block_bytes'], 'queue_depth': profile['qd'], 'jobs': profile['jobs'],
           'total_inflight_limit': profile['qd'] * profile['jobs'], 'engine': args.engine, 'direct_io': 1,
           **cache_columns(bool(audit['direct_fd'])),
           'host_block_read_coverage_verified': int(audit['host_block_read_coverage_verified']),
           'host_block_read_bytes': audit['host_block_read_bytes'],
           'qd_status': depth_status, 'requested_depth_bucket_pct': depth_pct,
           'fio_usr_cpu_pct': job.get('usr_cpu', ''), 'fio_sys_cpu_pct': job.get('sys_cpu', ''),
           'fio_cpu_pct': cpu, 'warnings': ';'.join(warnings),
           'file_size_bytes': args.size, 'runtime_requested_s': args.runtime, 'ramp_s': args.ramp,
           'repetition': rep, 'read_GiB_s': bw / GIB, 'read_MB_s': bw / 1e6,
           'read_IOPS': read['iops'], 'read_bytes': read['io_bytes'],
           'measured_runtime_s': read['runtime'] / 1000, **latency_metrics(read),
           'fio_fd_O_DIRECT_verified': int(bool(audit['direct_fd'])) if SYSTEM == 'Linux' else '',
           'fio_fd_F_NOCACHE_verified': int(bool(audit['direct_fd'])) if SYSTEM == 'Darwin' else '',
           'temperature_start_max_C': max(audit['temperature_start_c'].values(), default=''),
           'temperature_peak_C': audit['temperature_peak_c'] if audit['temperature_peak_c'] is not None else '',
           'started_utc': audit['started_utc']}
    for key in ['1', '2', '4', '8', '16', '32', '>=64']:
        row['iodepth_' + key.replace('>=', 'ge') + '_pct'] = depth.get(key, 0)
    return row


def summarize(rows):
    def group_key(r):
        return r['profile'], r['block_bytes'], r['queue_depth'], r['jobs']
    keys = sorted(set(group_key(r) for r in rows), key=lambda k: (k[0] != 'seq_read', k[1], k[2], k[0]))
    result = []
    for key in keys:
        group = [r for r in rows if group_key(r) == key]
        first = group[0]
        bw = [r['read_GiB_s'] for r in group]
        row = {k: first[k] for k in ['label', 'profile', 'block_bytes', 'queue_depth', 'jobs', 'engine',
                                     'file_size_bytes', 'runtime_requested_s', 'ramp_s']}
        row.update({'direct_io': 1, 'os_family': first.get('os_family', SYSTEM),
                    'cache_mode': first.get('cache_mode', CACHE_MODE),
                    'host_page_cache_bypass_verified_all': int(all(r['host_page_cache_bypass_verified'] for r in group)),
                    'host_block_read_coverage_verified_all': int(all(r.get('host_block_read_coverage_verified', 0) for r in group)),
                    'media_cache_bypass_verified': 0, 'total_inflight_limit': key[2] * key[3],
                    'qd_status': ';'.join(sorted(set(r.get('qd_status', '') for r in group))),
                    'warnings': ';'.join(sorted(set(r['warnings'] for r in group if r.get('warnings')))),
                    'repetitions_completed': len(group), 'read_GiB_s_median': statistics.median(bw),
                    'read_GiB_s_min': min(bw), 'read_GiB_s_max': max(bw),
                    'read_GiB_s_stdev': statistics.stdev(bw) if len(bw) > 1 else ''})
        for field in ['read_MB_s', 'read_IOPS', 'fio_usr_cpu_pct', 'fio_sys_cpu_pct', 'fio_cpu_pct',
                      'slat_mean_us', 'clat_mean_us', 'lat_mean_us'] + [
                      kind + '_p' + pct + '_us' for kind in ['lat', 'clat'] for pct in ['50', '95', '99', '99_9']]:
            values = [r[field] for r in group if r.get(field, '') != '']
            row[field + '_median'] = statistics.median(values) if values else ''
        result.append(row)
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
                       'os_family': low['os_family'], 'cache_mode': low['cache_mode'], 'engine': low['engine'],
                       'sequential_block_KiB': seq['block_bytes'] / 1024,
                       'sequential_QD': seq['queue_depth'], 'random_low_QD': low['queue_depth'],
                       'sequential_jobs': seq['jobs'], 'random_low_jobs': low['jobs'], 'random_high_jobs': high['jobs'],
                       'comparison_scope': 'common bulk reference; request size and concurrency can differ',
                       'high_warnings': high['warnings'],
                       'random_high_QD': high['queue_depth'], 'sequential_GiB_s': s,
                       'random_low_QD_GiB_s': l, 'random_high_QD_GiB_s': h,
                       'low_QD_vs_sequential_pct': 100 * l / s,
                       'high_QD_vs_sequential_pct': 100 * h / s, 'high_vs_low_QD_x': h / l,
                       'sequential_qd_status': seq['qd_status'], 'low_QD_status': low['qd_status'],
                       'high_QD_status': high['qd_status'],
                       'sequential_reps': seq['repetitions_completed'],
                       'low_QD_reps': low['repetitions_completed'], 'high_QD_reps': high['repetitions_completed']})
    return result


def write_tables(out, rows):
    write_csv(out / 'runs.csv', rows)
    summary = summarize(rows)
    write_csv(out / 'summary.csv', summary)
    write_csv(out / 'comparison.csv', comparisons(summary))
    write_csv(out / 'matched_random_comparison.csv', matched_comparisons(summary))
    return summary


def matched_comparisons(summary):
    result = []
    for row in summary:
        if not row['profile'].startswith('random_read_'):
            continue
        ref = next((r for r in summary if r['profile'] == row['profile'].replace('random_read', 'matched_seq')
                    and all(r[k] == row[k] for k in ['block_bytes', 'queue_depth', 'jobs', 'engine'])), None)
        if ref:
            result.append({'label': row['label'], 'block_bytes': row['block_bytes'],
                           'queue_depth': row['queue_depth'], 'jobs': row['jobs'], 'engine': row['engine'],
                           'random_GiB_s': row['read_GiB_s_median'], 'sequential_GiB_s': ref['read_GiB_s_median'],
                           'random_to_matched_seq': row['read_GiB_s_median'] / ref['read_GiB_s_median']})
    return result


def workload_row(row):
    # Every byte returned by these synthetic fio profiles is counted as payload.
    # No invented 512 B application demand or fixed amplification factor.
    return dict(row, workload=row['profile'], physical_request_bytes=row['block_bytes'],
                useful_request_bytes=row['block_bytes'], storage_GiB_s=row['read_GiB_s'],
                useful_GiB_s=row['read_GiB_s'])


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
               'os_family': first.get('os_family', 'Linux'), 'cache_mode': first.get('cache_mode', 'O_DIRECT'),
               'physical_request_bytes': first['physical_request_bytes'],
               'useful_request_bytes': first['useful_request_bytes'], 'workload_QD': first['queue_depth'],
               'jobs': first['jobs'], 'engine': first['engine'],
               'file_size_bytes': first['file_size_bytes'], 'runtime_requested_s': first['runtime_requested_s'],
               'ramp_s': first['ramp_s'], 'repetitions_completed': len(group),
               'storage_GiB_s_median': physical, 'storage_GiB_s_min': min(bw), 'storage_GiB_s_max': max(bw),
               'useful_GiB_s_median': useful,
               'random_comparison_scope': 'same fio engine and request size; distribution/concurrency may differ',
               'low_random_concurrency_matches_workload': int(low['queue_depth'] == first['queue_depth'] and
                                                              low['jobs'] == first['jobs']) if low else ''}
        for key, ref in [('seq', seq), ('random_low_QD', low), ('random_high_QD', high)]:
            value = ref['read_GiB_s_median'] if ref else None
            row[key + '_block_bytes'] = ref['block_bytes'] if ref else ''
            row[key + '_queue_depth'] = ref['queue_depth'] if ref else ''
            row[key + '_jobs'] = ref['jobs'] if ref else ''
            row[key + '_GiB_s'] = value if value is not None else ''
            row['storage_vs_' + key + '_pct'] = 100 * physical / value if value else ''
            row['useful_vs_' + key + '_pct'] = 100 * useful / value if value else ''
        result.append(row)
    write_csv(out / 'workload_comparison.csv', result)
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog='bench.sh', description='Linux/macOS storage read benchmark with mandatory cache bypass '
        '(O_DIRECT on Linux, F_NOCACHE on macOS). '
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
    parser.add_argument('--engine', choices=['auto', 'libaio', 'io_uring', 'psync'], default='auto', help='Linux: libaio/io_uring/psync; macOS: psync')
    parser.add_argument('--fio', default='fio', help='fio executable name or path')
    parser.add_argument('--seed', type=nonnegative, default=20261008, help='reproducible profile order and random I/O seed')
    parser.add_argument('--pause', type=nonnegative, default=1, help='idle seconds between runs')
    parser.add_argument('--workloads', choices=['patterns', 'none'], default='patterns',
                        help='also measure three synthetic fio patterns: Zipf, contiguous runs, batch/parallel reads')
    parser.add_argument('--max-temp-c', type=float, help='wait before each run until all discovered target sensors are <= this value')
    parser.add_argument('--cool-timeout', type=positive, default=600, help='maximum temperature wait, seconds')
    parser.add_argument('--seq-jobs', type=positive, default=4 if SYSTEM == 'Darwin' else 1,
                        help='sequential workers; QD is per worker')
    parser.add_argument('--high-jobs', type=positive, default=4 if SYSTEM == 'Darwin' else 1,
                        help='high-concurrency workers; e.g. --high-jobs 4 --high-qd 32')
    parser.add_argument('--batch-qd', type=positive, default=16, help='Linux async batch size')
    parser.add_argument('--zipf-theta', type=float, default=1.2, help='Zipf skew, positive and not 1')
    parser.add_argument('--matched-seq', action='store_true', help='add sequential references at each random size/QD/jobs')
    parser.add_argument('--uring-tuned', action='store_true', help='io_uring fixedbufs + registerfiles (requires --engine io_uring)')
    parser.add_argument('--hipri', action='store_true', help='io_uring polling; requires OS/device support and --engine io_uring')
    parser.add_argument('--allow-indirect', action='store_true', help='allow Linux loop/zram/dm/bcache/unresolved stacks as host-path measurements')
    parser.add_argument('--settle', type=nonnegative, default=0, help='idle seconds after initializing and probing the file')
    args = parser.parse_args(argv)
    try:
        args.random_bs = sorted(set(size_bytes(x.strip()) for x in args.random_bs.split(',')))
    except argparse.ArgumentTypeError as e:
        parser.error('--random-bs: ' + str(e))
    if args.low_qd >= args.high_qd:
        parser.error('--low-qd must be less than --high-qd')
    if max(args.low_qd, args.high_qd, args.seq_qd, args.batch_qd) > 4096:
        parser.error('queue depths above 4096 are not supported')
    if args.size < 64 * MIB or args.size % MIB:
        parser.error('--size must be at least 64M and a multiple of 1M')
    for bs in [args.seq_bs] + args.random_bs:
        if bs < 4096 or bs % 4096 or args.size % bs:
            parser.error('request sizes must be multiples of 4K and divide --size exactly')
    if not (0 < args.zipf_theta < float('inf')) or args.zipf_theta == 1:
        parser.error('--zipf-theta must be finite, positive, and not 1')
    if args.uring_tuned or args.hipri:
        if args.engine != 'io_uring':
            parser.error('--uring-tuned and --hipri require --engine io_uring')
    for jobs in [args.seq_jobs, args.high_jobs]:
        if jobs > 256 or args.size % jobs or (args.size // jobs) % MIB:
            parser.error('job counts must be <=256 and divide --size into whole MiB regions')
        if any((args.size // jobs) % bs for bs in [args.seq_bs] + args.random_bs):
            parser.error('each worker region must be divisible by every request size')
    if args.max_temp_c is not None and not (0 < args.max_temp_c < 150):
        parser.error('--max-temp-c must be between 0 and 150')
    return args


def main(argv=None):
    args = parse_args(argv)
    if SYSTEM not in ('Linux', 'Darwin') or sys.version_info < (3, 8):
        raise RuntimeError('Linux or macOS and Python 3.8+ are required')
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
                           'Install using apt install fio, dnf install fio, or brew install fio on macOS.')
    engines = capture([fio, '--enghelp']) or ''
    supported = ['psync'] if SYSTEM == 'Darwin' else ['libaio', 'io_uring', 'psync']
    if args.engine == 'auto':
        args.engine = next((e for e in supported if e in engines.split()), None)
    if not args.engine or args.engine not in engines.split() or args.engine not in supported:
        raise RuntimeError('fio needs an available engine supported on this OS: ' + ', '.join(supported))
    if shutil.disk_usage(target).free < args.size + GIB:
        raise RuntimeError('Insufficient space: need --size plus 1 GiB of reserve on target')
    if args.engine == 'psync':
        print('psync: per-worker QD=1; --seq-jobs/--high-jobs set worker concurrency, not device QD.', flush=True)
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
    print('Output: %s\nTarget: %s\nFile: %.3f GiB; engine=%s; direct=1' %
          (out, target, args.size / GIB, args.engine), flush=True)
    all_profiles = profiles(args) + (pattern_profiles(args) if args.workloads == 'patterns' else [])
    work_count = len(all_profiles) - len(profiles(args))
    print('Profiles: %d baselines + %d synthetic fio patterns, each x %d repetitions; %.1f min of read I/O + preparation/startup' %
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
            print('Preparing a fully written data file (' + CACHE_MODE + ' + fsync)...', flush=True)
            prep_cmd = base + ['--name=prepare', '--rw=write', '--bs=1M',
                               '--iodepth=' + ('1' if args.engine == 'psync' else '32'),
                               '--refill_buffers=1', '--scramble_buffers=1', '--end_fsync=1',
                               '--output=' + str(out / 'raw' / 'prepare.json')]
            job, _ = run_fio(prep_cmd, 'prepare', out, data, env, max(300, args.size / MIB * 2), False)
            if job['write']['io_bytes'] != args.size or data.stat().st_size != args.size:
                raise RuntimeError('Data file was not completely initialized')
            save_json(out / 'direct_io_validation.json', direct_probe(data))
            if args.settle:
                print('Settling for %d seconds...' % args.settle, flush=True)
                time.sleep(args.settle)
            env['status'] = 'running'
            save_json(out / 'environment.json', env)
            for rep in range(1, args.repeats + 1):
                order = list(all_profiles)
                random.Random(args.seed + rep).shuffle(order)
                for profile in order:
                    if args.pause:
                        time.sleep(args.pause)
                    cooling(env, args)
                    stem = '%s_bs%d_qd%d_jobs%d_rep%d' % (profile['profile'], profile['block_bytes'],
                                                         profile['qd'], profile['jobs'], rep)
                    print('[%d/%d] %s' % (len(rows) + len(work_rows) + 1, len(order) * args.repeats, stem), flush=True)
                    cmd = measurement_command(base, args, profile, rep, out / 'raw' / (stem + '.json'), stem)
                    job, audit = run_fio(cmd, stem, out, data, env, args.runtime + args.ramp + 120, True)
                    row = metric_row(args, profile, rep, job, audit)
                    if row['warnings']:
                        print('  WARNING: ' + row['warnings'], flush=True)
                    if profile['kind'] == 'pattern_proxy':
                        work_rows.append(workload_row(row))
                    else:
                        rows.append(row)
                    write_tables(out, rows)
                    workload_tables(out, work_rows, rows)
                    print('  %.3f GiB/s | %.0f IOPS | total p99 %.1f us | CPU %.1f%%' %
                          (row['read_GiB_s'], row['read_IOPS'], row['lat_p99_us'], row['fio_cpu_pct']), flush=True)
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
    print('\n%-26s %8s %6s %5s %12s %12s %12s' %
          ('Profile', 'KiB', 'QD/job', 'jobs', 'GiB/s med', 'IOPS med', 'p99 us med'))
    for r in summary:
        print('%-26s %8g %6d %5d %12.3f %12.0f %12.1f' %
              (r['profile'], r['block_bytes'] / 1024, r['queue_depth'], r['jobs'], r['read_GiB_s_median'],
               r['read_IOPS_median'], r['lat_p99_us_median']))
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
