# [Bug] Deadlock - 멀티프로세스 자원 순환 대기로 인한 무응답

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true`로 실행하면 부트는 성공하지만, 두 worker가 서로 다른 자원을 획득한 뒤 상대 자원을 기다리는 상태에 진입합니다. 프로세스 PID는 계속 존재하고 로그는 `WAITING ... BLOCKED`에서 멈추며, 25초 관측 동안 RSS와 CPU 변화도 거의 없습니다.

## 2. Reproduction Path (재현 경로)

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=30 MULTI_THREAD_ENABLE=true \
  ./agent-leak-app-arm64 > evidence/deadlock/app-final.log 2>&1 &
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 25 \
  -o evidence/deadlock/monitor-final.log
```

PID와 스레드 증거는 [ps-ef-final.txt](../evidence/deadlock/ps-ef-final.txt), [threads-final.txt](../evidence/deadlock/threads-final.txt), [threads-final-after.txt](../evidence/deadlock/threads-final-after.txt), [top-final.txt](../evidence/deadlock/top-final.txt), [top-final-after.txt](../evidence/deadlock/top-final-after.txt)에 있습니다.

Workaround 비교:

```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=30 MULTI_THREAD_ENABLE=false \
  ./agent-leak-app-arm64 > evidence/deadlock/app-after.log 2>&1 &
```

## 3. Evidence & Logs (증거 자료)

### 3.1 PID와 스레드/프로세스 존재

```text
APP_PIDS=208,218
agent 208 ... /work/agent-leak-app-arm64
agent 218 208 ... /work/agent-leak-app-arm64
```

초기와 12초 후 모두 동일한 애플리케이션 프로세스 집합이 존재했습니다. `ps -L`에서도 PID 218과 연결된 실행 단위가 계속 남았습니다.

```text
초기: 208 ... RSS 1576, 218 ... RSS 16700
후기: 208 ... RSS 1576, 218 ... RSS 16824
```

### 3.2 마지막 애플리케이션 로그

```text
[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```

원문: [app-final.log](../evidence/deadlock/app-final.log)

### 3.3 CPU/MEM 정체

```text
[18:46:49] PIDS:2 CPU:0.80% RSS_KB:18404 THREADS:4
[18:46:59] PIDS:2 CPU:0.50% RSS_KB:18400 THREADS:4
[18:47:04] PIDS:2 CPU:0.30% RSS_KB:18400 THREADS:4
[18:47:05] MONITOR:TIME_LIMIT_REACHED
```

`top -H`에서도 leader 프로세스는 sleeping 상태이고 CPU 0.0%로 관측되었습니다. 원문: [monitor-final.log](../evidence/deadlock/monitor-final.log)

## 4. Root Cause Analysis (원인 분석)

교착상태의 네 가지 조건이 모두 관측됩니다.

1. 상호 배제: `Shared_Memory_A`와 `Socket_Pool_B`는 동시에 한 worker만 보유할 수 있는 잠금 자원입니다.
2. 점유 대기: Worker-1은 A를 보유한 채 B를 기다리고, Worker-2는 B를 보유한 채 A를 기다립니다.
3. 비선점: 로그상 어느 worker도 자신이 보유한 자원을 강제로 반납하지 않습니다.
4. 순환 대기: `Worker-1 → Socket_Pool_B → Worker-2 → Shared_Memory_A → Worker-1`의 cycle이 형성됩니다.

따라서 프로세스가 살아 있다는 사실만으로 정상이라고 볼 수 없고, 로그 정지·낮은 CPU·고정된 RSS를 함께 확인해야 합니다.

## 5. Workaround & Verification (조치 및 검증)

| 항목 | Before | After |
|---|---|---|
| `MULTI_THREAD_ENABLE` | `true` | `false` |
| 로그 | 두 worker가 `WAITING/BLOCKED`에서 정지 | `Thread-A/B/C` 작업이 100% 완료 |
| 프로세스 상태 | PID 208/218 유지, 25초 무응답 | 정상 모니터링 및 MemoryWorker 진행 |
| 결과 | Deadlock 재현 | Deadlock 회피 |

임시 조치는 동시 처리를 끄는 것입니다. 근본 해결은 모든 worker가 잠금을 동일한 순서로 획득하게 하고, timeout·try-lock·rollback 경로를 추가하여 순환 대기를 끊는 것입니다.
