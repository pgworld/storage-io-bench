# Storage I/O benchmark

## 기존 결과를 3열 CSV로 정리

```sh
git pull
sh summarize.sh storage-results/20261008T010819Z-zrd1rvk9
```

지정한 폴더에 **`normalized.csv` 하나**를 만듭니다. 기존 결과 CSV만 읽으며
벤치마크를 다시 실행하지 않습니다. Linux와 macOS에서 Python 3만 있으면 됩니다.
폴더명만 지정하는 `sh summarize.sh 20261008T010819Z-zrd1rvk9`도 가능합니다.

| 열 | 의미 |
|---|---|
| `workload` | 접근 패턴 또는 기준 측정명. 요청 크기·QD·여러 worker를 구분 |
| `effective_bw_GiB_s` | 저장된 반복별 처리량의 중앙값 |
| `normalized_to_seq_read` | effective BW ÷ 같은 결과 폴더의 bulk 순차 읽기 BW. **순차 읽기 = 1.0** |

fio 기준은 `summary.csv`의 `read_GiB_s_median`, 패턴은 `workload_comparison.csv`의
`useful_GiB_s_median`을 씁니다. 정규화 기준 `seq_read`가 없거나 여러 개이거나 0이면 중단합니다.
기존 CSV는 보존하며 재실행하면 파생 파일 `normalized.csv`만 갱신합니다.
`--workloads none`으로 측정한 결과도 지원합니다. 중단된 결과는 경고와 함께 완료된 행만 정리합니다.

**v1 결과도 지원합니다.** 기존 GNN·임베딩·토큰 이름은 각각 `legacy_uniform_4KiB_python_QD1`,
`legacy_uniform_4KiB_python_512B_payload_QD1`, `legacy_uniform_16KiB_python_QD1`로 바꿔 표시합니다.
이 측정은 실제 AI 접근 특성을 구현하지 않은 Python 동기 균일 랜덤 읽기였습니다.
기존 임베딩 행의 유효 BW는 512 B payload 기준으로 그대로 보존합니다. 4 KiB / 512 B = 8배라는
산술 비율을 실제 임베딩 시스템에서 측정한 증폭률로 해석하면 안 됩니다.
요약을 다시 만들어도 과거의 측정 방식은 바뀌지 않습니다.

## 새 측정 실행

**`sh bench.sh` 한 번으로 캐시 우회 읽기와 CSV를 생성합니다.**
실행 코드는 이 파일 하나에 들어 있습니다. Python 3.8 이상과 Flexible I/O Tester **fio 3.x**가
필요합니다. Python 패키지, GPU, root 권한은 필요 없습니다.

```sh
# 필요한 패키지 설치 (처음 한 번)
brew install fio python                 # macOS / Homebrew
sudo apt-get install fio python3         # Debian / Ubuntu

sh bench.sh                             # 현재 디렉터리가 있는 스토리지
sh bench.sh --target /mnt/ssd/bench --label server-a
sh bench.sh --target /Volumes/MySSD --label external-ssd
```

`--target`은 측정할 스토리지의 **기존 디렉터리**입니다. raw device는 받지 않습니다.
새 임시 파일만 쓰고 읽으며 기존 사용자 파일은 건드리지 않습니다. 기본 파일 크기는 8 GiB이고
1 GiB의 여유 공간도 요구합니다. `pip install fio`는 필요한 fio 설치 방법이 아닙니다.
완료·오류·SIGINT·SIGTERM 시 임시 데이터 파일을 정리하고 결과를 보존합니다.
SIGKILL 또는 전원 장애로 남은 `.storage-io-bench-*` 디렉터리는 실행 종료 확인 후 직접 정리합니다.

## 기본 구성: 측정 횟수 유지

**12가지 설정 × 3회**, 설정당 워밍업 2초 + 본 측정 10초입니다. 읽기 시간 약 7.2분에
파일 준비·실행 간격·시작 시간이 더해집니다. v2에서도 기본 파일 크기·시간·반복 수를 늘리지 않았습니다.
모든 기준과 패턴을 하나의 목록에 넣어 매 반복 seed에 따라 순서를 섞습니다.

| 측정 | 요청 크기 | Linux 기본 동시성 | macOS 기본 동시성 |
|---|---|---|---|
| Bulk sequential reference | 1 MiB | 1 job × QD32 | 4 workers × QD1 |
| Uniform random, low | 4 / 16 / 128 / 1024 KiB | 1 × QD1 | 1 × QD1 |
| Uniform random, high | 같은 4종 | 1 × QD128 | 4 × QD1 |
| `zipf_read_4k` | 4 KiB, Zipf θ=1.2 편중 | 1 × QD1 | 1 × QD1 |
| `batched_uniform_4k` / `parallel_uniform_4k` | 4 KiB | 16개씩 제출·완료를 기다리는 batch | 독립적인 psync 4 workers |
| `contiguous_run_16k` | 임의 시작점에서 16 KiB씩 64회 연속 읽기 | 1 × QD1 | 1 × QD1 |

**새 패턴도 합성 I/O 패턴(`pattern_proxy`)입니다.** Zipf 편중, mini-batch 동시 요청,
토큰/KV 구간의 연속성을 분리해 표현하며 실제 모델·GNN 그래프·임베딩 서버·KV 관리기의
종단 성능이나 수집된 실제 trace는 아닙니다. 모든 패턴을 fio로 실행하므로 Python의 요청별
`preadv`/복사 오버헤드가 기준 대비 차이에 끼어들지 않습니다. 새 패턴은 읽은 모든 바이트를
payload로 세며 임의의 512 B 수요나 8배 증폭률을 만들지 않습니다.

고정 32,768-offset trace는 제거했습니다. 균일 랜덤은 전체 설정 범위를 사용하는 LFSR이며,
여러 worker는 같은 전체 파일을 동일 크기의 겹치지 않는 영역으로 나눕니다.
fio 한 실행 안에서 워밍업 후 통계만 측정하며 별도 Python 루프를 처음부터 재시작하지 않습니다.
전체 범위를 다 읽으면 시간 기반 실행은 다시 순환할 수 있습니다. Zipf의 반복 접근은 의도된 편중이며,
연속 구간끼리도 겹칠 수 있습니다. 모든 패턴에서 전역적으로 중복이 없다는 뜻은 아닙니다.

## 동시성과 비율 해석

Linux 기본 엔진은 사용 가능한 `libaio`, `io_uring`, `psync` 순으로 선택합니다.
명시한 엔진이나 polling 옵션이 실패하면 다른 경로로 몰래 전환하지 않습니다.
macOS는 **`psync` + 여러 worker**를 사용합니다. POSIX AIO의 대기 요청 수를 높은 장치 QD로
취급하지 않습니다. psync에서는 `--seq-qd`, `--high-qd`, `--batch-qd` 대신 worker 수가 동시성을
결정하며 요청별 QD는 1입니다. Mac의 parallel 항목은 Linux의 batch barrier를 재현하지 않습니다.
**Mac worker 동시성과 Linux async QD 수치는 직접 동등 비교할 수 없습니다.**

fio QD는 장치 큐 깊이가 아니라 fio가 관리하는 outstanding 요청 수입니다.
해당 버킷 비율이 **90% 미만이면 경고**합니다. 마지막 버킷이 `>=64`이므로
`observed_ge64_exact_depth_unknown`도 정확한 QD128 달성이나 장치 포화를 보장하지 않습니다.
Mac 여러 worker에는 `sync_worker_concurrency_not_device_qd`를 기록합니다.

fio의 `usr_cpu`, `sys_cpu`와 합을 CSV에 내보내며 합이 **90% 이상이면**
`host_cpu_pressure_possible`을 기록하고 출력합니다. 여러 job의 group reporting 수치는
job 평균이므로 개별 worker의 최댓값이나 전체 시스템 CPU 사용률이 아닙니다.
경고가 없다는 사실만으로 장치가 포화됐다고 판단하지 않습니다.

bulk 순차 기준 정규화는 **공통 기준에 대한 비율**입니다. 요청 크기와 동시성도 달라지므로
순수한 랜덤 접근 페널티를 의미하지 않습니다. 순차 기준은 성능 상한도 아니며 비율은 1을 넘을 수 있습니다.
같은 BS·QD·worker 수를 맞춘 순차/랜덤 비교는 `--matched-seq`로 추가합니다.

```sh
# 단일 제출 스레드가 제한할 때: 총 설정 outstanding 한도 128 유지
sh bench.sh --high-jobs 4 --high-qd 32

# 같은 크기·동시성의 순차 기준 추가 (기본 설정에서는 실행하지 않음)
sh bench.sh --matched-seq

# Linux io_uring 등록 버퍼/파일; polling은 지원 장치에서만 별도 선택
sh bench.sh --engine io_uring --uring-tuned
sh bench.sh --engine io_uring --uring-tuned --hipri

# Mac의 독립 동기 worker 수 변경
sh bench.sh --seq-jobs 4 --high-jobs 8
```

## 캐시 우회 검증의 범위

Linux **O_DIRECT**, macOS **F_NOCACHE**를 강제합니다. Buffered I/O fallback은 없습니다.

1. 새 파일 전체를 fio `direct=1`로 쓰고 fsync하며 초기화 바이트를 확인합니다.
2. 정렬된 버퍼로 같은 1 MiB 구간을 두 번 읽어, 매번 프로세스 디스크 I/O 카운터가 증가하는지 검사합니다.
3. 각 fio 측정에서 실행 중 대상 FD의 O_DIRECT/F_NOCACHE 플래그와 JSON의 `direct=1`을 확인합니다.
4. Linux에서는 sysfs의 partition 부모와 slave 장치 체인을 따라가며 loop·zram·dm·bcache 경로를 기본 거부합니다.
5. Linux의 **각 fio 실행 전후** leaf whole-disk `stat`의 읽은 sector 수를 기록하고,
   증가 바이트가 fio의 본 측정 `io_bytes` 이상인지 대조합니다. 작거나 카운터가 reset되면 중단합니다.

`host_page_cache_bypass_verified`는 호스트 파일 데이터 캐시 우회 확인입니다.
`host_block_read_coverage_verified`는 위 Linux 장치 카운터 대조입니다.
macOS에서는 Linux식 whole-disk 카운터 대조를 하지 않으므로 해당 값은 0입니다.
모든 환경에서 **`media_cache_bypass_verified=0`**입니다. 물리 NAND 접근 검증이라는 뜻은 없습니다.
Linux whole-disk 카운터는 다른 프로세스와 워밍업 읽기도 포함하므로 요청별 추적·증명이 아닙니다.

VM의 virtio/NVMe도 호스트에서 보이는 장치일 수 있습니다. 하이퍼바이저·RAID 컨트롤러·SSD 내부
캐시는 배제하지 못합니다. VM 탐지 결과와 storage 경로를 환경 파일에 기록하지만 탐지는 완전하지 않습니다.
RAM 파일시스템은 거부합니다. loop/dm 등 간접 경로를 의도적으로 측정할 때만 `--allow-indirect`를
사용하며, 이 경우 결과는 **해당 호스트 경로 성능**입니다. O_DIRECT 자체 검증은 계속 요구합니다.
macOS 디스크 이미지, 원격 파일시스템, DAX/PMem은 지원 대상이 아닙니다.

## 저장 파일과 지연 통계

기본 결과 경로는 `storage-results/<UTC>-<고유 ID>/`이며 마지막에 출력됩니다.
CSV는 UTF-8 BOM 형식입니다. 간단한 비교에는 `summarize.sh`로 만든 세 열 파일을 사용합니다.

| 파일 | 내용 |
|---|---|
| `normalized.csv` | 요약 스크립트가 만드는 3열 표 |
| `summary.csv`, `comparison.csv` | fio 기준별 중앙값·최소·최대·표본 표준편차, 기준 대비 비율 |
| `workload_comparison.csv` | 합성 패턴별 중앙값 및 기준 대비 비율 |
| `runs.csv`, `workload_runs.csv` | **각 반복 전체 수치**, CPU, latency, fio QD 분포, 검증 범위·경고 |
| `matched_random_comparison.csv` | `--matched-seq` 사용 시 BS·QD·jobs가 같은 순차/랜덤 비율 |
| `environment.json` | 실행 설정·완료 상태, OS·CPU·장치·가상화·전원 관련 관측값 |
| `direct_io_validation.json` | 반복 읽기와 프로세스 카운터 검증 |
| `raw/` | 모든 fio JSON·정확한 명령·로그·실행 전후 장치 카운터/FD audit |

**`lat`은 제출 지연을 포함한 fio 전체 I/O latency**, `clat`은 완료 대기, `slat`은 제출 지연입니다.
`lat_percentiles=1`로 전체 지연 p50/p95/p99/**p99.9**를 수집하고 clat도 함께 보존합니다.
CSV의 p99.9 열은 `lat_p99_9_us`입니다. sync 엔진에서 slat가 별도로 측정되지 않으면 빈칸입니다.
fio 전체 latency도 모델의 전처리·배치 대기·GPU 실행까지 포함하는 latency는 아닙니다.
요약의 분위수 중앙값은 **반복별 분위수의 중앙값**이며 모든 요청을 합친 분위수가 아닙니다.

기본 n=3은 가벼운 탐색용 기술 통계입니다. 표준편차나 중앙값 하나로 통계적 유의성을 주장하지 않습니다.
각 반복과 fio 원본을 모두 남기며, 엄밀한 비교에서는 `--repeats 5` 이상을 선택하고 개별 값도 검토합니다.
자동 bootstrap이나 반복 확대는 수행하지 않습니다.

## 장치 상태와 선택적 추가 확인

초기화 직후 데이터를 읽으므로 SLC 캐시와 background folding의 영향을 받을 수 있습니다.
8 GiB 주소 범위는 큰 데이터셋보다 FTL 매핑 캐시/HMB에 유리할 수 있습니다.
기본 실행은 장치를 전면 precondition하거나 SLC 배출을 보장하지 않습니다.

```sh
# 필요한 경우에만 더 큰 주소 범위, 준비 후 idle, 반복 수 변경
sh bench.sh --size 64G --settle 30 --repeats 5

# 기능 점검용; 성능 결론에 쓰지 않는 짧은 실행
sh bench.sh --size 128M --runtime 1 --ramp 0 --repeats 1 --pause 0

sh bench.sh --workloads none
sh bench.sh --output ./result-server-a
sh bench.sh --max-temp-c 70 --cool-timeout 600
sh bench.sh --help
```

Linux에서 읽을 수 있는 CPU governor, cpuidle driver/CPU0 C-state enable 상태,
NVMe APST **커널 기본 latency 파라미터**, leaf 장치 `max_sectors_kb`를 기록합니다.
APST 파라미터는 각 컨트롤러의 실제 전원 상태/설정 조회를 대신하지 않습니다.
수집할 수 없는 값은 null/빈 목록이며 어떤 전원 설정도 변경하지 않습니다.
발견한 장치 온도 센서는 각 실행 전후 기록합니다. `--max-temp-c`는 실행 전 대기 옵션이며
macOS 또는 센서가 없는 환경에서는 해당 옵션을 거부합니다.

## 개발 검증

```sh
python3 checks/test_summary.py           # CSV만 읽고 쓰는 테스트
python3 tests/test_bench.py              # 계산·명령·장치 경로·검증 로직
python3 tests/test_bench.py --integration # 새 128 MiB 파일로 짧은 실제 fio 검증
```

GitHub Actions에서 Linux/macOS 통합 테스트를 실행합니다. CI의 작은 파일·VM 처리량은
사용자 SSD의 성능 평가를 대신하지 않습니다. 측정 결과와 환경 파일은 Git 추적에서 제외합니다.

구현 근거: [fio 공식 옵션 문서](https://fio.readthedocs.io/en/master/fio_doc.html),
[Linux 장치 I/O 통계](https://www.kernel.org/doc/html/latest/admin-guide/iostats.html),
[fio macOS direct=1 구현](https://github.com/axboe/fio/blob/master/os/os-mac.h),
[Apple FD 구조](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h),
[Apple 디스크 I/O 카운터 구조](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h).
