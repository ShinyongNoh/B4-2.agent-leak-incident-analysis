# [Bug] OOM Crash - MemoryGuard 임계치 초과에 따른 프로세스 종료

## 1. Description (현상 설명)

`MEMORY_LIMIT=50`으로 `agent-leak-app-arm64`를 실행하면 메모리 워커의 Heap이 25MB에서 50MB로 증가한 직후 프로세스가 종료됩니다. 종료는 약 5초 내 발생했으며, 애플리케이션 로그에 `MemoryGuard`의 임계치 초과 및 self-termination 메시지가 남았습니다.

동일한 실행 조건에서 `MEMORY_LIMIT=512`로 올리면 35초 관측 동안 프로세스가 살아 있고 Heap/RSS가 계속 증가했습니다. 따라서 문제는 OS가 먼저 프로세스를 죽인 것이 아니라, 애플리케이션 내부 MemoryGuard가 설정값에 도달한 프로세스를 보호 목적으로 종료한 사례로 분류했습니다.

## 2. Reproduction Path (재현 경로)

```bash
MEMORY_LIMIT=50 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false \
  ./agent-leak-app-arm64 > /tmp/oom-app-before.log 2>&1 &
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 120 \
  -o evidence/oom/before.log
```

Workaround 비교:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=30 MULTI_THREAD_ENABLE=false \
  ./agent-leak-app-arm64 > /tmp/oom-app-after.log 2>&1 &
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 35 \
  -o evidence/oom/after.log
```

실행 시 `AGENT_HOME`, `AGENT_PORT=15034`, 업로드·키·로그 디렉터리와 `secret.key`를 먼저 구성해야 합니다. 애플리케이션 로그와 관제 로그를 합친 최종 증거는 [before.log](../evidence/oom/before.log), [after.log](../evidence/oom/after.log)에서 확인할 수 있습니다.

## 3. Evidence & Logs (증거 자료)

### 3.1 `monitor.sh` 메모리 추이

Before 관측에서 RSS는 다음처럼 증가했습니다.

```text
[17:58:09] RSS_KB:18276  MEM:0.20%
[17:58:11] RSS_KB:43880  MEM:0.50%
[17:58:14] PROCESS:agent-leak-app-arm64 STATUS:NOT_FOUND
[17:58:14] MONITOR:PROCESS_EXITED PID:205
```

원문: [before.log](../evidence/oom/before.log)

After 관측에서는 35초 동안 프로세스가 종료되지 않았고 RSS가 약 18MB에서 300MB까지 증가했습니다.

```text
[17:58:43] RSS_KB:18292
[17:58:49] RSS_KB:69764
[17:58:52] RSS_KB:95368
[17:59:04] RSS_KB:197784
[17:59:13] RSS_KB:274596
[17:59:16] RSS_KB:300200
[17:59:17] MONITOR:TIME_LIMIT_REACHED
```

원문: [after.log](../evidence/oom/after.log)

### 3.2 종료 직전 애플리케이션 로그

```text
[MemoryWorker] Current Heap: 25MB
[MemoryWorker] Current Heap: 50MB
[MemoryGuard] Memory limit exceeded (50MB >= 50MB)
[MemoryGuard] Self-terminating process 217 to prevent system instability.
Killed
```

실행 결과는 컨테이너에서 종료 코드 137로 관측되었습니다. 이는 보호 종료 직후 프로세스가 SIGKILL 계열로 끝난 결과와 일치합니다. 원문: [before.log](../evidence/oom/before.log)

## 4. Root Cause Analysis (원인 분석)

1. `MemoryWorker`의 Heap 값이 시간에 따라 25MB 단위로 증가하고, `monitor.sh`의 RSS도 같은 방향으로 증가했습니다. 수집된 자료만으로는 stripped 바이너리의 정확한 allocation site를 확인할 수 없지만, 런타임 관측상 데이터 또는 버퍼가 회수되지 않고 유지되는 메모리 누수/의도된 누적 workload 패턴입니다.
2. `MEMORY_LIMIT=50`에 도달하자 `MemoryGuard`가 임계치 초과를 명시적으로 기록하고 self-termination을 수행했습니다.
3. 따라서 이번 종료의 직접 원인은 kernel OOM killer가 아니라 애플리케이션의 MemoryGuard 정책입니다. 근본 결함을 해결하려면 소스 코드에서 누적 컨테이너·버퍼의 lifetime, 참조 해제, batch 상한을 확인해야 합니다.

## 5. Workaround & Verification (조치 및 검증)

| 항목 | Before | After |
|---|---:|---:|
| `MEMORY_LIMIT` | 50MB | 512MB |
| 종료 시점 | 약 5초, Heap 50MB | 35초 관측 동안 생존 |
| RSS 관측 | 18,276KB → 종료 | 18,292KB → 300,200KB |
| 핵심 결과 | `MemoryGuard` 종료 | `TIME_LIMIT_REACHED`, 프로세스 생존 |

임시 조치는 `MEMORY_LIMIT` 상향입니다. 이는 누수 자체를 제거하지 않으므로, 실제 해결은 누적 데이터 상한·주기적 정리·heap profile 기반 allocation 추적으로 진행해야 합니다.
