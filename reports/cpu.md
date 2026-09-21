# [Bug] CPU Latency - CPU Watchdog 임계치 위반에 따른 프로세스 종료

## 1. Description (현상 설명)

`CPU_MAX_OCCUPY=100`으로 실행한 경우 애플리케이션의 `CpuWorker Current Load`가 5.00%에서 54.08%까지 상승했습니다. 54.08%에서 `CPU Threshold Violated`가 기록된 직후 프로세스가 종료되었습니다.

반대로 `CPU_MAX_OCCUPY=30`에서는 부하가 30.00%에 도달한 뒤 `Peak reached ... Starting cooldown`으로 전환되고, 30초 관측 동안 종료되지 않았습니다.

## 2. Reproduction Path (재현 경로)

Before:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=30 MULTI_THREAD_ENABLE=false \
  ./agent-leak-app-arm64 > evidence/cpu/app-baseline-final.log 2>&1 &
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 30 \
  -o evidence/cpu/monitor-baseline-final.log
```

After:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false \
  ./agent-leak-app-arm64 > evidence/cpu/app-after-long.log 2>&1 &
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 100 \
  -o evidence/cpu/monitor-after-long.log
```

전체 원문은 [baseline app log](../evidence/cpu/app-baseline-final.log), [after app log](../evidence/cpu/app-after-long.log), [baseline monitor](../evidence/cpu/monitor-baseline-final.log), [after monitor](../evidence/cpu/monitor-after-long.log)에 있습니다.

## 3. Evidence & Logs (증거 자료)

### 3.1 애플리케이션 부하 추이 및 종료 로그

`CPU_MAX_OCCUPY=30`:

```text
[CpuWorker] Current Load: 5.00%
[CpuWorker] Current Load: 27.15%
[CpuWorker] Peak reached (30.00%). Starting cooldown...
[CpuWorker] Current Load: 30.00%
[CpuWorker] Current Load: 7.42%
```

`CPU_MAX_OCCUPY=100`:

```text
[CpuWorker] Current Load: 5.00%
[CpuWorker] Current Load: 33.51%
[CpuWorker] Current Load: 41.79%
[CpuWorker] Current Load: 46.33%
[CpuWorker] Current Load: 54.08%
[CpuWorker] CPU Threshold Violated! (54.080000000000005%).
Terminated
```

원문: [app-after-long.log](../evidence/cpu/app-after-long.log)

### 3.2 Linux 관제 및 해석 범위

`monitor.sh`는 앱의 fork된 프로세스를 합산했으며, 종료 직전까지 PID 217과 PIDS=2가 관측되었습니다. 해당 컨테이너에서 Linux `ps`가 측정한 실제 host CPU는 약 0.7~1.2% 범위였습니다.

```text
[18:04:15] PIDS:2 CPU:1.20% RSS_KB:18356
[18:04:17] PIDS:2 CPU:1.10% RSS_KB:18356
[18:04:18] PROCESS:agent-leak-app-arm64 STATUS:NOT_FOUND
[18:04:18] MONITOR:PROCESS_EXITED PID:217
```

시스템 load average도 관측 당시 0.00~0.02 수준이었습니다. 따라서 이 바이너리의 `CpuWorker Current Load`는 실제 host CPU와 동일한 계측값이 아니라 애플리케이션 내부 Watchdog 부하 지표로 보입니다. 리포트에서는 이 차이를 숨기지 않고, 애플리케이션 정책 부하와 OS 관제 CPU를 분리해 기록했습니다. 원문: [monitor-after-long.log](../evidence/cpu/monitor-after-long.log)

## 4. Root Cause Analysis (원인 분석)

1. `CPU_MAX_OCCUPY=100`에서 내부 부하 상승을 제한할 cooldown 경로가 충분히 작동하지 않아 `CpuWorker` 값이 54.08%까지 진행되었습니다.
2. 내부 Watchdog가 임계치 위반을 감지하여 오류가 아닌 보호 동작으로 종료했습니다. 로그에 kernel OOM, segmentation fault, 예외 traceback은 없고 `CPU Threshold Violated`와 `Terminated`가 직접 연결되어 있습니다.
3. OS 전체의 load average는 낮았으므로, 이번 케이스의 재현 조건은 시스템 전체 CPU 고갈보다는 애플리케이션이 정의한 CPU 보호 정책에 의해 결정되었습니다.

## 5. Workaround & Verification (조치 및 검증)

| 항목 | Before | After |
|---|---:|---:|
| `CPU_MAX_OCCUPY` | 30% | 100% |
| 애플리케이션 내부 부하 | 30% 도달 후 cooldown | 5% → 54.08% 상승 |
| 실행 결과 | 30초 관측 동안 생존 | 임계치 위반 직후 종료 |
| 종료 로그 | 없음 | `CPU Threshold Violated`, `Terminated` |

이번 비교에서 `CPU_MAX_OCCUPY`를 높이는 조정은 보호 여유를 줄여 종료를 유발했습니다. 운영 Workaround는 낮은 상한을 유지하고 workload를 분할하는 것입니다. 근본적으로는 CPU 사용량을 작업 단위로 제한하고, watchdog 기준을 실제 host CPU 계측과 일관되게 정의해야 합니다.
