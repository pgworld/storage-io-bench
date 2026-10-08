# Storage I/O benchmark

## 기존 결과를 3열 CSV로 정리

```sh
git pull
sh summarize.sh storage-results/20261008T010819Z-zrd1rvk9
```

지정한 폴더의 **`normalized.csv`**를 만듭니다. 기존 `summary.csv`와
`workload_comparison.csv`만 읽으며 벤치마크를 다시 실행하지 않습니다.
Linux와 macOS에서 Python3만 있으면 실행할 수 있습니다.
폴더명만 지정하는 `sh summarize.sh 20261008T010819Z-zrd1rvk9`도 가능합니다.

| 열 | 의미 |
|---|---|
| `workload` | 워크로드명. fio 항목은 요청 크기·QD를 이름에 포함 |
| `effective_bw_GiB_s` | 저장된 반복 측정의 중앙값. AI 접근 패턴은 **유효 데이터/시간** |
| `normalized_to_seq_read` | 해당 effective BW ÷ 순차 읽기 BW. **순차 읽기 = 1.0** |

순차 읽기, 요청 크기별 low/high-QD 랜덤 읽기, AI 접근 패턴 순으로 한 행씩 정리합니다.
fio 항목은 `read_GiB_s_median`, AI 항목은 `useful_GiB_s_median`을 사용합니다.
예를 들어 임베딩 조회는 실제 전달하는 512 B를 기준으로 하며, 물리적으로 읽은 4 KiB를
effective BW로 부풀리지 않습니다. `--workloads none`으로 측정한 폴더도 지원합니다.
정규화 기준은 같은 폴더의 `seq_read` 결과 한 개이며, 분모가 0이거나 모호하면 중단합니다.
기존 측정 CSV는 보존하고, 다시 실행하면 파생 파일 `normalized.csv`만 갱신합니다.

## 측정 실행

**`sh bench.sh` 한 번으로 Direct I/O 실측과 비교 CSV를 생성합니다.**
`bench.sh` 파일 하나에 실행 코드가 모두 들어 있습니다. **Linux와 macOS**에서 동작하며 Python 3.8 이상,
Flexible I/O Tester **fio 3.x**가 필요하며 Python 추가 패키지나 GPU, root 권한은 필요하지 않습니다.

Linux는 `O_DIRECT`, macOS는 **`F_NOCACHE`**로 호스트 데이터 캐시를 우회합니다.
운영체제를 자동 감지하므로 Mac에서도 같은 `sh bench.sh` 명령을 사용합니다.

```sh
sh bench.sh
```

현재 디렉터리가 있는 스토리지를 측정합니다. 다른 디스크를 측정하려면 그 디스크에 있는
**기존 디렉터리**를 지정합니다.

```sh
sh bench.sh --target /mnt/ssd/bench --label server-a
```

처음 한 번 필요한 시스템 패키지 설치 예:

```sh
# macOS (Homebrew가 설치되어 있는 경우)
brew install fio python
# Debian / Ubuntu
sudo apt-get install fio python3
# Fedora / RHEL 계열: 배포판의 fio 패키지 저장소 사용
sudo dnf install fio python3
```

Mac에서 이미 저장소를 받았다면 `git pull`로 갱신한 뒤 실행합니다.

```sh
sh bench.sh --label my-mac
# 외장 SSD: 해당 볼륨이 마운트된 기존 경로를 지정
sh bench.sh --target /Volumes/MySSD --label external-ssd
```

`pip install fio`는 이 도구의 설치 방법이 아닙니다. 기본 설정은 8 GiB의 새 임시 파일을
쓰기 때문에 대상에 **9 GiB 이상 여유 공간**이 있어야 합니다. 파일 준비·장치 속도에 따라
대략 8~10분 이상 걸립니다. 데이터 파일은 완료·오류·SIGINT·SIGTERM 시 정리하며 결과는 보존합니다.
SIGKILL 또는 전원 장애 후에는 실행이 끝났는지 확인하고 대상 디렉터리의
`.storage-io-bench-*` 잔여 디렉터리를 직접 정리해야 합니다.

## 기본 측정 구성

| 측정 | 요청 크기 | QD | 반복 |
|---|---:|---:|---:|
| Sequential read | 1 MiB | 32 | 3 |
| Random read, low QD | 4 / 16 / 128 / 1024 KiB | 1 | 각각 3 |
| Random read, high QD | 4 / 16 / 128 / 1024 KiB | 128 | 각각 3 |
| GNN feature gather 접근 패턴 | 4 KiB | 1 | 3 |
| Embedding lookup 접근 패턴 | 유효 512 B / 물리 요청 4 KiB | 1 | 3 |
| Token fetch 접근 패턴 | 16 KiB | 1 | 3 |

각 측정은 워밍업 2초 후 10초 동안 실행합니다. fio는 단일 job이며 Linux에서는
`libaio`, `io_uring`, `posixaio` 순서로 설치된 비동기 엔진을 선택합니다.
macOS에서는 `posixaio`를 사용합니다. 지원되는 비동기 엔진이 없으면 중단합니다.
각 반복의 fio 설정 순서를 고정 seed로 섞고, 이어서 세 접근 패턴을 실행합니다.

AI 세 항목은 **실제 캐시 우회 읽기를 수행하는 합성 접근 패턴(`pattern_proxy`)**입니다.
전체 모델, 학습, GPU 추론, 실제 GNN 라이브러리·임베딩 서버의 성능이 아닙니다.
이 독립 실행 도구에는 PyTorch 체크포인트·JPEG 디코딩 등 원래 연구의 native API 실험을
포함하지 않습니다. 패턴 측정에서는 미리 만든 32,768개 무작위 offset 목록을 순환하며,
Linux에서는 동기 `preadv`, macOS에서는 정렬된 버퍼에 대한 동기 `pread`를 사용하며
유효 데이터 복사의 시간을 포함합니다.

## 생성되는 CSV

결과는 `./storage-results/<UTC 시각>-<고유 ID>/`에 저장합니다.
경로는 실행 마지막에도 출력합니다. CSV는 Excel에서 읽기 쉬운 UTF-8 BOM 형식이며,
단위가 열 이름에 포함됩니다.

| 파일 | 내용 |
|---|---|
| **`comparison.csv`** | 요청 크기별 한 행. seq / random low QD / random high QD 중앙값과 성능 비율 |
| **`workload_comparison.csv`** | AI 접근 패턴별 한 행. 스토리지·유효 처리량 및 세 기준 대비 비율 |
| `summary.csv` | fio 설정별 중앙값·최소·최대·표본 표준편차, IOPS, p50/p99 지연시간 |
| `runs.csv` | fio 반복별 원시 수치, 관측 QD 분포, Direct I/O 확인, 온도 |
| `workload_runs.csv` | 접근 패턴 반복별 물리 읽기 바이트·유효 바이트·시간·증폭률 |
| `environment.json` | OS·CPU·메모리·디바이스·마운트·fio 버전·실행 설정·완료 상태 |
| `direct_io_validation.json` | 같은 영역의 반복 읽기, OS별 캐시 우회 플래그·프로세스 디스크 카운터 검증 |
| `raw/` | fio JSON, 정확한 명령 인자, 로그, 실행 중 캐시 우회 플래그·온도 확인 |

`comparison.csv`의 핵심 열:

```text
random_block_KiB,sequential_GiB_s,random_low_QD_GiB_s,random_high_QD_GiB_s,
low_QD_vs_sequential_pct,high_QD_vs_sequential_pct,high_vs_low_QD_x
```

실제 파일에는 label, 순차 요청 크기, 각 QD와 완료된 반복 수도 함께 있습니다.
`os_family`, `cache_mode`, `engine`으로 실행 경로를 구분합니다.
`cache_bypass_verified=1`은 해당 OS의 캐시 우회 검증 통과를 뜻합니다.
macOS에서는 Linux 전용 `fio_fd_O_DIRECT_verified` 열을 빈칸으로 두고
`fio_fd_F_NOCACHE_verified=1`로 기록합니다.
`100 × workload / baseline`이 기준 대비 백분율입니다.
`high_vs_low_QD_x`는 같은 random 요청 크기에서 QD 증가에 따른 배수입니다.
GiB/s는 2³⁰ bytes/s, MB/s는 10⁶ bytes/s입니다.
요약의 `clat_p99_us_median`은 **반복별 p99의 중앙값**이며, 모든 요청을 합친 p99가 아닙니다.
측정이 중단되면 완료한 행만 남습니다. 비교에 앞서 `environment.json`의
`status`가 `complete`인지와 각 CSV의 반복 수를 확인합니다.

## Direct I/O 검증

초기 버전은 Linux의 `O_DIRECT`, `/proc`, `libaio`에 맞춰 구현했기 때문에 Linux로
제한했습니다. macOS에는 같은 이름의 `O_DIRECT`가 없으며, fio는 `direct=1`을
`fcntl(F_NOCACHE, 1)`로 구현합니다. 이 도구도 OS별 검증 경로를 사용합니다.

| 항목 | Linux | macOS |
|---|---|---|
| 캐시 우회 | `O_DIRECT` | `F_NOCACHE` |
| fio 실행 중 파일 검증 | `/proc/<pid>/fdinfo` | `libproc.proc_pidfdinfo`의 `FNOCACHE` |
| 직접 연 파일 검증 | `F_GETFL`의 `O_DIRECT` | `F_NOCACHE` 호출 성공 + `F_GETFL`의 `FNOCACHE` |
| 프로세스 디스크 읽기 카운터 | `/proc/self/io.read_bytes` | `proc_pid_rusage`의 `ri_diskio_bytesread` |
| 기본 비동기 엔진 | `libaio` | `posixaio` |

1. 새 임시 파일 전체를 fio `direct=1`로 쓰고 `fsync`합니다. 전체 초기화 바이트를 확인합니다.
2. 직접 연 파일의 OS별 캐시 우회 플래그를 확인합니다.
3. 같은 1 MiB 영역을 두 번 읽고 **두 번 모두** 프로세스 디스크 읽기 카운터가
   요청 바이트 이상 증가했는지 검사합니다.
4. fio의 모든 측정에 `direct=1`을 강제하고, 실행 중 대상 파일의 캐시 우회 플래그와
   fio JSON 설정을 검증합니다.
5. 패턴 측정에서도 캐시 우회 플래그와 프로세스 디스크 읽기 바이트를 검사합니다.

검증에 실패하면 중단합니다. Buffered I/O로 전환하지 않습니다. RAM 파일시스템은 거부하며,
컨테이너나 OS 보안 설정으로 플래그·디스크 카운터 검증이 차단돼도 성공으로 처리하지 않습니다.
로컬 블록 스토리지와 Direct I/O를 지원하는 파일시스템을 대상으로 합니다.
Windows, DAX/PMem, RAM 디스크, 디스크 이미지, 원격 파일시스템은 지원 대상에 포함하지 않습니다.

**호스트의 파일 데이터 캐시를 우회합니다. SSD 내부 DRAM·컨트롤러 캐시는 포함됩니다.**
이는 파일시스템·커널·장치 경로를 포함한 호스트 관측 성능이며 NAND 단독 성능은 아닙니다.

## 옵션 예

```sh
# fio 기준 성능만 측정
sh bench.sh --workloads none

# 짧은 기능 점검: 성능 결론에 쓰는 설정이 아님
sh bench.sh --size 128M --runtime 1 --ramp 0 --repeats 1 --pause 0

# 두 서버에서 이 설정을 동일하게 사용하고 label만 변경
sh bench.sh --target /mnt/ssd/bench --label server-b \
  --size 16G --runtime 30 --ramp 5 --repeats 3 \
  --low-qd 1 --high-qd 128 --random-bs 4K,16K,128K,1M

# 결과 위치 지정: 기존 디렉터리를 덮어쓰지 않음
sh bench.sh --output ./result-server-a

# 대상 장치 센서가 있으면 실행 전 냉각 대기. 센서가 없으면 오류.
sh bench.sh --max-temp-c 70 --cool-timeout 600

sh bench.sh --help
```

실행 시간·파일 크기·QD·요청 크기·fio 버전·엔진을 동일하게 맞추면 환경 비교가 쉽습니다.
스토리지를 사용하는 다른 작업, CPU 속도, 파일시스템, 장치 온도와 빈 공간도 결과에 영향을 줍니다.
기본 설정은 온도 대기를 강제하지 않으며 발견한 대상 센서 온도를 기록합니다.
macOS에서는 장치 온도 수집을 지원하지 않으므로 온도 열을 비워 두며
`--max-temp-c`를 지정하면 측정 전에 오류를 반환합니다.
`--max-temp-c`는 발견한 대상 센서 전체의 최대값을 기준으로 **측정 전** 대기합니다.
측정 중 온도 상승을 막는 기능은 아닙니다. 센서가 없으면 CSV 온도 칸은 비어 있습니다.

high QD 결과는 지정한 설정의 관측값입니다. 장치의 절대 최대 성능을 보장하지 않습니다.
fio `runs.csv`의 `iodepth_*_pct`에서 실제 요청 깊이 분포를 볼 수 있습니다.
fio의 마지막 버킷은 `>=64`이므로 QD 128의 정확한 평균 관측 깊이는 이 버킷만으로 알 수 없습니다.
특히 macOS의 POSIX AIO에는 OS별 대기 요청 수 제한이 있습니다. `environment.json`에
`kern.aiomax`, `kern.aioprocmax`, `kern.aiothreads`를 수집하며 시스템 설정은 변경하지 않습니다.
요청한 QD의 버킷에 도달한 표본이 1% 미만이면 `qd_status=below_requested_depth_bucket`과
경고를 남깁니다. `comparison.csv`의 `high_QD_status`도 확인하세요.
`observed_ge64_exact_depth_unknown`은 64 이상 버킷을 관측했지만 정확히 128을 확인한 것은
아니라는 뜻입니다. OS 간 비교에서는 엔진과 달성한 QD 분포의 차이까지 고려해야 합니다.

패턴의 random 비교는 **같은 물리 요청 크기**를 사용합니다. 해당 요청 크기의 fio 결과가
없으면 비율을 비워 둡니다. 엔진과 offset trace는 다르며, low QD를 변경하면 QD도 다를 수
있으므로 완전히 같은 trace를 재생한 효율 측정으로 해석하지 않습니다.
순차 기준의 요청 크기는 기본 1 MiB이므로 작은 random 요청과는 요청 크기도 다릅니다.
Embedding의 유효 처리량은 512 B 기준이고 물리 읽기는 4 KiB여서 약 8배 증폭됩니다.

## 개발 검증

```sh
python3 tests/test_bench.py
# fio를 실제 실행하는 추가 검증. 새 임시 파일만 사용.
python3 tests/test_bench.py --integration
```

GitHub Actions에 Linux와 macOS의 실제 uncached I/O 통합 테스트를 구성합니다.
CI 가상 장치의 처리량은 사용자 Mac의 SSD 성능을 대신하지 않습니다.

구현 근거:
[fio macOS의 direct=1 구현](https://github.com/axboe/fio/blob/master/os/os-mac.h),
[Apple F_NOCACHE 안내](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/FilePerformance.html),
[Apple 프로세스 FD 구조](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h),
[Apple 디스크 I/O 카운터 구조](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h),
[fio 공식 문서](https://fio.readthedocs.io/en/latest/fio_doc.html).
측정 데이터와 환경 정보는 `.gitignore`로 제외합니다.
