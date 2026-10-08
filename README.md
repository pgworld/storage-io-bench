# Storage I/O benchmark

**`sh bench.sh` 한 번으로 Direct I/O 실측과 비교 CSV를 생성합니다.**
`bench.sh` 파일 하나에 실행 코드가 모두 들어 있습니다. Linux, Python 3.8 이상,
Flexible I/O Tester **fio 3.x**가 필요하며 Python 추가 패키지나 GPU, root 권한은 필요하지 않습니다.

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
# Debian / Ubuntu
sudo apt-get install fio python3
# Fedora / RHEL 계열: 배포판의 fio 패키지 저장소 사용
sudo dnf install fio python3
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

각 측정은 워밍업 2초 후 10초 동안 실행합니다. fio는 단일 job, `libaio` 우선이며
설치된 엔진에 따라 `io_uring`을 선택합니다. 두 엔진이 없으면 중단합니다.
각 반복의 fio 설정 순서를 고정 seed로 섞고, 이어서 세 접근 패턴을 실행합니다.

AI 세 항목은 **실제 O_DIRECT 읽기를 수행하는 합성 접근 패턴(`pattern_proxy`)**입니다.
전체 모델, 학습, GPU 추론, 실제 GNN 라이브러리·임베딩 서버의 성능이 아닙니다.
이 독립 실행 도구에는 PyTorch 체크포인트·JPEG 디코딩 등 원래 연구의 native API 실험을
포함하지 않습니다. 패턴 측정에서는 미리 만든 32,768개 무작위 offset 목록을 순환하며,
동기 `preadv`와 유효 데이터 복사의 시간을 포함합니다.

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
| `direct_io_validation.json` | 같은 영역의 반복 직접 읽기 및 `/proc/self/io` 검증 |
| `raw/` | fio JSON, 정확한 명령 인자, 로그, 실행 중 O_DIRECT 플래그·온도 확인 |

`comparison.csv`의 핵심 열:

```text
random_block_KiB,sequential_GiB_s,random_low_QD_GiB_s,random_high_QD_GiB_s,
low_QD_vs_sequential_pct,high_QD_vs_sequential_pct,high_vs_low_QD_x
```

실제 파일에는 label, 순차 요청 크기, 각 QD와 완료된 반복 수도 함께 있습니다.
`100 × workload / baseline`이 기준 대비 백분율입니다.
`high_vs_low_QD_x`는 같은 random 요청 크기에서 QD 증가에 따른 배수입니다.
GiB/s는 2³⁰ bytes/s, MB/s는 10⁶ bytes/s입니다.
요약의 `clat_p99_us_median`은 **반복별 p99의 중앙값**이며, 모든 요청을 합친 p99가 아닙니다.
측정이 중단되면 완료한 행만 남습니다. 비교에 앞서 `environment.json`의
`status`가 `complete`인지와 각 CSV의 반복 수를 확인합니다.

## Direct I/O 검증

1. 새 임시 파일 전체를 `direct=1`로 쓰고 `fsync`합니다. 읽기 전 전체 초기화 바이트를 확인합니다.
2. 직접 연 파일의 `fcntl(F_GETFL)`에서 `O_DIRECT`를 확인합니다.
3. 같은 1 MiB 영역을 두 번 읽고 **두 번 모두** `/proc/self/io.read_bytes` 증가를 확인합니다.
4. fio의 모든 측정에 `direct=1`을 강제하고, 실행 중 `/proc/<pid>/fdinfo`의
   대상 파일 `O_DIRECT` 플래그와 fio JSON 설정을 검증합니다.
5. 패턴 측정에서도 `O_DIRECT` 플래그와 실제 스토리지 읽기 바이트를 확인합니다.

검증에 실패하면 중단합니다. Buffered I/O로 전환하지 않습니다. RAM 파일시스템은 거부하며,
컨테이너 등에서 `/proc` 검증이 차단된 경우에도 성공 결과로 처리하지 않습니다.
로컬 블록 스토리지와 Direct I/O를 지원하는 파일시스템을 대상으로 합니다.
Windows/macOS, DAX/PMem, RAM 디스크, 원격 파일시스템은 지원 대상에 포함하지 않습니다.

**호스트의 Linux page cache를 제외합니다. SSD 내부 DRAM·컨트롤러 캐시는 포함됩니다.**
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
`--max-temp-c`는 발견한 대상 센서 전체의 최대값을 기준으로 **측정 전** 대기합니다.
측정 중 온도 상승을 막는 기능은 아닙니다. 센서가 없으면 CSV 온도 칸은 비어 있습니다.

high QD 결과는 지정한 설정의 관측값입니다. 장치의 절대 최대 성능을 보장하지 않습니다.
fio `runs.csv`의 `iodepth_*_pct`에서 실제 요청 깊이 분포를 볼 수 있습니다.
fio의 마지막 버킷은 `>=64`이므로 QD 128의 정확한 평균 관측 깊이는 이 버킷만으로 알 수 없습니다.

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

관련 설정 정의: [fio 공식 문서](https://fio.readthedocs.io/en/latest/fio_doc.html).
측정 데이터와 환경 정보는 `.gitignore`로 제외합니다.
