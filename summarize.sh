#!/bin/sh
# Summarize saved CSVs only. No fio, device access, or benchmark execution.
set -eu
if ! command -v python3 >/dev/null 2>&1; then
    echo 'ERROR: python3 is required.' >&2
    exit 1
fi
exec python3 - "$@" <<'PY'
import argparse
import csv
import json
import math
from pathlib import Path
import sys


FIELDS = ['workload', 'effective_bw_GiB_s', 'normalized_to_seq_read']


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream)
        rows = list(reader)
    if not rows:
        raise ValueError('%s is empty' % path.name)
    return rows


def number(row, key, source):
    try:
        value = float(row[key])
    except (KeyError, TypeError, ValueError):
        raise ValueError('%s: missing or invalid %s' % (source, key))
    if not math.isfinite(value) or value < 0:
        raise ValueError('%s: %s must be finite and nonnegative' % (source, key))
    return value


def integer(row, key, source):
    value = number(row, key, source)
    if value < 1 or value != int(value):
        raise ValueError('%s: %s must be a positive integer' % (source, key))
    return int(value)


def block_label(size):
    if size % (1024 * 1024) == 0:
        return '%dMiB' % (size // (1024 * 1024))
    if size % 1024 == 0:
        return '%dKiB' % (size // 1024)
    return '%dB' % size


def clean_rows(folder):
    summary = read_csv(folder / 'summary.csv')
    seq = [row for row in summary if row.get('profile') == 'seq_read']
    if len(seq) != 1:
        raise ValueError('summary.csv must contain exactly one seq_read reference; found %d' % len(seq))
    baseline = number(seq[0], 'read_GiB_s_median', 'summary.csv')
    if baseline <= 0:
        raise ValueError('seq_read bandwidth must be greater than zero')

    # One measured sequential reference, followed by size/QD-matched fio rows.
    profiles = {'seq_read', 'random_read_low_qd', 'random_read_high_qd',
                'matched_seq_low_qd', 'matched_seq_high_qd'}
    prepared = []
    for row in summary:
        profile = row.get('profile')
        if profile not in profiles:
            raise ValueError('Unknown profile in summary.csv: %r' % profile)
        bs = integer(row, 'block_bytes', 'summary.csv')
        qd = integer(row, 'queue_depth', 'summary.csv')
        jobs = integer(row, 'jobs', 'summary.csv') if row.get('jobs') else 1
        name = 'seq_read' if profile == 'seq_read' else ('matched_seq' if profile.startswith('matched_seq') else 'random_read')
        name += '_%s_QD%d' % (block_label(bs), qd)
        if jobs > 1:
            name += '_%dworkers' % jobs
        # Distinguish a psync high tier explicitly configured with one worker.
        if row.get('engine') == 'psync':
            name += '_psync'
            if profile.endswith('high_qd'):
                name += '_high'
            elif profile.endswith('low_qd'):
                name += '_low'
        bw = number(row, 'read_GiB_s_median', 'summary.csv')
        prepared.append(((profile != 'seq_read', bs, qd, jobs, profile), name, bw))
    prepared.sort(key=lambda item: item[0])
    result = [(name, bw) for _, name, bw in prepared]

    work_path = folder / 'workload_comparison.csv'
    if work_path.exists():
        workloads = read_csv(work_path)
        for row in sorted(workloads, key=lambda r: r.get('workload', '')):
            name = row.get('workload', '').strip()
            if not name:
                raise ValueError('workload_comparison.csv: missing workload name')
            legacy = {'gnn_feature_gather_4k': 'legacy_uniform_4KiB_python_QD1',
                      'embedding_lookup_512b': 'legacy_uniform_4KiB_python_512B_payload_QD1',
                      'token_fetch_16k': 'legacy_uniform_16KiB_python_QD1'}
            name = legacy.get(name, name)
            if row.get('workload_QD') and not name.startswith('legacy_'):
                name += '_QD%d' % integer(row, 'workload_QD', 'workload_comparison.csv')
                if row.get('jobs') and integer(row, 'jobs', 'workload_comparison.csv') > 1:
                    name += '_%dworkers' % integer(row, 'jobs', 'workload_comparison.csv')
            # Preserve saved useful-payload accounting, including legacy 512 B rows.
            bw = number(row, 'useful_GiB_s_median', 'workload_comparison.csv')
            result.append((name, bw))
    elif (folder / 'workload_runs.csv').exists():
        raise ValueError('workload_comparison.csv is missing although workload_runs.csv exists')

    names = [name for name, _ in result]
    if len(set(names)) != len(names):
        raise ValueError('Duplicate workload names; results may contain multiple environments')
    labels = {r.get('label', '') for r in summary}
    if work_path.exists():
        labels.update(r.get('label', '') for r in workloads)
    if len(labels) > 1:
        raise ValueError('Input CSVs contain different environment labels')
    return [{'workload': name, 'effective_bw_GiB_s': '%.6f' % bw,
             'normalized_to_seq_read': '%.6f' % (bw / baseline)} for name, bw in result]


def main(argv=None):
    parser = argparse.ArgumentParser(prog='summarize.sh', description=
        'Read existing result CSVs and write three columns: workload, effective BW, '
        'and effective BW / sequential read BW (seq_read = 1.0). No benchmarks run.')
    parser.add_argument('result_dir', help='result directory, or its name under ./storage-results/')
    args = parser.parse_args(argv)
    folder = Path(args.result_dir).expanduser()
    if not folder.is_dir() and len(folder.parts) == 1:
        folder = Path('storage-results') / folder
    folder = folder.resolve(strict=True)
    if not folder.is_dir():
        raise ValueError('result_dir must be a directory')
    rows = clean_rows(folder)
    env_path = folder / 'environment.json'
    if env_path.exists():
        status = json.loads(env_path.read_text(encoding='utf-8')).get('status')
        if status and status != 'complete':
            print('WARNING: benchmark status is %s; only saved completed rows are summarized.' % status,
                  file=sys.stderr)
    output = folder / 'normalized.csv'
    # Exclusive creation prevents accidentally overwriting a symlink target.
    # Only the derived CSV is replaced; all measurement inputs remain unchanged.
    import os
    import tempfile
    fd, temporary = tempfile.mkstemp(prefix='.normalized-', suffix='.csv', dir=str(folder))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8-sig', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=FIELDS)
            writer.writeheader()
            for row in rows:
                safe = dict(row)
                if safe['workload'].startswith(('=', '+', '-', '@', '\t', '\r')):
                    safe['workload'] = "'" + safe['workload']
                writer.writerow(safe)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(output)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
PY
