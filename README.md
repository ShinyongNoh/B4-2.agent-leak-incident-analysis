# agent-leak-app 장애 분석 미션

ARM64 Linux용 `agent-leak-app`을 glibc 기반 Debian ARM64 컨테이너에서 실행하고, `monitor.sh`와 Linux 표준 도구로 OOM, CPU Watchdog, Deadlock을 재현·분석한 제출용 자료입니다.

## 산출물

- [OOM 리포트](reports/oom.md)
- [CPU 리포트](reports/cpu.md)
- [Deadlock 리포트](reports/deadlock.md)
- [관제 스크립트](monitor.sh)
- 원문 증거: [`evidence/`](evidence/)

각 리포트는 현상, 재현 경로, 로그·관제 증거, 근본 원인, Workaround, Before/After 검증을 포함합니다.

## 실행 환경 및 공통 설정

실행 계정은 root가 아닌 `agent`로 구성했습니다.

```bash
export AGENT_HOME=/tmp/agent_home
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$AGENT_HOME/logs

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
printf '%s' agent_api_key_test > "$AGENT_KEY_PATH/secret.key"
```

관제 스크립트는 다음처럼 실행합니다.

```bash
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 120 -o evidence/<case>/monitor.log
```

`monitor.sh`는 바이너리가 fork하는 프로세스를 고려해 일치하는 프로세스들의 CPU, MEM, RSS, 스레드 수를 합산하고, 종료 시점 또는 관측 시간 종료도 로그로 남깁니다. 로그 파일은 실행할 때마다 새로 작성되며, 반복되는 시스템 메모리와 load 출력은 제외하고 장애 분석에 필요한 정보만 한 줄에 정리합니다.

```text
# time                     PID(S)          CPU%    MEM%       RSS       THR STATE
2026-09-21 05:17:01+0000  PID=203,204       CPU=  2.90% MEM=  0.50% RSS=   42.86MB THR=2   STATE=Ss
2026-09-21 05:17:04+0000  EVENT=PROCESS_EXITED PID=203
2026-09-21 05:17:04+0000  EVENT=MONITOR_FINISHED
```

## 검증 요약

| Case | Before | After / 결과 |
|---|---|---|
| OOM | `MEMORY_LIMIT=50`: 약 5초 후 `MemoryGuard` 종료 | `MEMORY_LIMIT=512`: 35초 관측 동안 생존, RSS 약 18MB → 300MB |
| CPU | `CPU_MAX_OCCUPY=30`: 30%에서 cooldown, 30초 관측 생존 | `CPU_MAX_OCCUPY=100`: 내부 부하 54.08%에서 `CPU Threshold Violated` 후 종료 |
| Deadlock | `MULTI_THREAD_ENABLE=true`: 두 자원에 대한 순환 대기, 25초 동안 무응답 | `false`: `Thread-A/B/C` 작업 완료 및 정상 모니터링 진행 |

## 새 데스크톱 환경에서 처음부터 실행하기

이 절차는 새 macOS, Windows 또는 Linux 데스크톱에서 GitHub 저장소를 Clone한 뒤 Docker의 glibc 기반 ARM64 Linux 환경에서 프로젝트를 실행하는 방법입니다. 제공 바이너리는 `ARM64 Linux ELF`이므로 Docker Desktop 또는 ARM64 Linux 환경을 사용하는 것을 권장합니다.

### 1. 사전 준비

호스트 운영체제에 다음 프로그램을 설치합니다.

- Git
- Docker Desktop 또는 Docker Engine
- Docker가 실행 중인 상태

Docker가 정상인지 확인합니다.

```bash
docker --version
docker info
```

`docker info`가 오류 없이 출력되어야 합니다. Docker Desktop 사용자는 Docker Desktop을 먼저 실행한 뒤 다음 단계로 진행합니다.

### 2. 저장소 Clone

호스트 터미널에서 본인의 저장소 주소를 넣어 실행합니다.

```bash
git clone https://github.com/ShinyongNoh/B4-2.agent-leak-incident-analysis.git agent-leak-app
cd agent-leak-app
```

파일이 존재하는지 확인합니다.

```bash
ls -l agent-leak-app-arm64 monitor.sh
chmod +x agent-leak-app-arm64 monitor.sh
file agent-leak-app-arm64
```

`file` 결과에 다음과 비슷한 내용이 있어야 합니다.

```text
ELF 64-bit LSB executable, ARM aarch64, dynamically linked
```

저장소에 바이너리를 포함하지 않았다면, 과제에서 제공된 `agent-leak-app-arm64` 파일을 Clone한 프로젝트 폴더에 직접 복사해야 합니다.

### 3. Ubuntu가 아닌 glibc 기반 ARM64 컨테이너 실행

호스트의 프로젝트 폴더에서 다음 명령을 실행합니다.

```bash
docker run --rm -it --platform linux/arm64 --name agent-leak-lab -v "$PWD":/work -w /work debian:bookworm-slim bash
```

이제 컨테이너 내부의 `root@...:/work#` 프롬프트에서 다음 단계를 진행합니다. 이 컨테이너는 프로젝트 파일을 `/work`에 연결하므로, 컨테이너 안에서 생성한 로그와 증거 파일은 호스트 프로젝트 폴더에도 남습니다.

### 4. 컨테이너 내부 도구 설치

```bash
apt-get update
apt-get install -y procps psmisc passwd util-linux file ca-certificates
```

설치되는 명령은 다음 용도로 사용합니다.

- `ps`, `top`: 프로세스와 스레드 관찰
- `pgrep`, `pkill`: 프로세스 검색과 종료
- `su`, `useradd`: 일반 사용자로 애플리케이션 실행
- `file`: 바이너리 형식 확인

컨테이너 아키텍처와 파일을 다시 확인합니다.

```bash
uname -m
file /work/agent-leak-app-arm64
```

정상적인 컨테이너 아키텍처는 `aarch64`입니다.

### 5. 실행 사용자와 필수 환경 구성

아래 명령을 한 줄씩 실행합니다. 변수명에 `\\_` 같은 역슬래시를 넣지 마십시오. 반드시 `AGENT_HOME`, `MEMORY_LIMIT`처럼 입력해야 합니다.

```bash
id agent >/dev/null 2>&1 || useradd -m -u 1000 agent
```

```bash
export AGENT_HOME=/tmp/agent_home
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$AGENT_HOME/logs
```

```bash
mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
printf '%s' agent_api_key_test > "$AGENT_KEY_PATH/secret.key"
chown -R agent:agent "$AGENT_HOME"
mkdir -p /work/evidence/demo/oom /work/evidence/demo/cpu /work/evidence/demo/deadlock
```

### 6. 부트 시퀀스 확인

먼저 기본 설정으로 애플리케이션을 한 번 실행합니다.

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
```

아래 명령은 한 번만 실행합니다.

```bash
su -p -s /bin/bash agent -c 'exec /work/agent-leak-app-arm64' > /work/boot-check.log 2>&1 &
```

3초 뒤 로그를 확인합니다.

```bash
sleep 3
cat /work/boot-check.log
```

다음 두 문구가 있어야 성공입니다.

```text
All Boot Checks Passed!
Agent READY
```

확인 후 프로세스를 종료합니다.

```bash
pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
```

`su` 명령 뒤에 `[1] 253`처럼 표시되는 것은 백그라운드 작업 번호와 PID이며, 성공 여부는 반드시 `boot-check.log`로 확인해야 합니다.

### 7. 반복 실행용 함수 등록

세 케이스를 편하게 실행하려면 컨테이너 안에서 아래 함수를 한 번 등록합니다.

```bash
run_and_monitor() {
  combined_log="$1"
  duration="$2"
  app_tmp="/tmp/agent-leak-app.$$.log"
  monitor_tmp="/tmp/agent-leak-monitor.$$.log"

  su -p -s /bin/bash agent -c 'exec /work/agent-leak-app-arm64' > "$app_tmp" 2>&1 &
  sleep 1
  ./monitor.sh -n agent-leak-app-arm64 -i 1 -d "$duration" -o "$monitor_tmp"
  pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
  sleep 1

  {
    printf '%s\n' '=== APPLICATION LOG ==='
    awk '{print}' "$app_tmp"
    printf '\n%s\n' '=== MONITOR LOG ==='
    awk '{print}' "$monitor_tmp"
  } > "$combined_log"

  rm -f "$app_tmp" "$monitor_tmp"
}
```

이 함수는 애플리케이션 로그와 관제 로그를 하나의 `before.log` 또는 `after.log`로 합칩니다. 실행 중간 파일은 `/tmp`에 만들고 최종 증거 폴더에는 남기지 않습니다. 세 케이스는 반드시 한 번에 하나씩 실행해야 합니다. 모든 케이스가 동일한 `15034` 포트를 사용하기 때문입니다.

### 8. OOM 재현과 Workaround 비교

Before 실행:

```bash
export MEMORY_LIMIT=50
export CPU_MAX_OCCUPY=100
export MULTI_THREAD_ENABLE=false
run_and_monitor /work/evidence/demo/oom/before.log 120
```

Before 로그에서 다음 내용을 확인합니다.

```text
[MemoryGuard] Memory limit exceeded
[MemoryGuard] Self-terminating process
Killed
```

After 실행:

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
run_and_monitor /work/evidence/demo/oom/after.log 35
```

After에서는 35초 동안 프로세스가 살아 있고 RSS가 계속 증가하는지 확인합니다.

### 9. CPU Watchdog 재현과 비교

Before 실행:

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
run_and_monitor /work/evidence/demo/cpu/before.log 30
```

다음과 같은 cooldown 로그가 나타나면 정상입니다.

```text
[CpuWorker] Peak reached (30.00%). Starting cooldown...
```

After 실행:

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=100
export MULTI_THREAD_ENABLE=false
run_and_monitor /work/evidence/demo/cpu/after.log 100
```

다음 로그가 나타나면 CPU Watchdog 재현에 성공한 것입니다.

```text
[CpuWorker] Current Load: 54.08%
[CpuWorker] CPU Threshold Violated!
Terminated
```

`CpuWorker Current Load`는 애플리케이션 내부 부하 지표이고, `monitor.sh`의 CPU 값은 Linux 프로세스 관측값입니다. 이번 바이너리에서는 두 값이 다르게 측정될 수 있으므로 리포트 작성 시 두 값을 같은 수치로 취급하지 않습니다.

### 10. Deadlock 재현과 프로세스 관찰

Deadlock을 재현합니다.

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=true
```

애플리케이션을 시작합니다.

```bash
DEADLOCK_APP_TMP=/tmp/agent-leak-deadlock-app.log
DEADLOCK_MONITOR_TMP=/tmp/agent-leak-deadlock-monitor.log
su -p -s /bin/bash agent -c 'exec /work/agent-leak-app-arm64' > "$DEADLOCK_APP_TMP" 2>&1 &
sleep 7
```

PID와 프로세스 목록을 저장합니다.

```bash
APP_PIDS=$(pgrep -f '^/work/agent-leak-app-arm64$' | paste -sd, -)
LEADER_PID=${APP_PIDS%%,*}
echo "APP_PIDS=$APP_PIDS" > /work/evidence/demo/deadlock/processes.txt
ps -ef | grep -E 'agent-leak-app|PID' | grep -v grep >> /work/evidence/demo/deadlock/processes.txt
```

스레드와 `top` 상태를 저장합니다.

```bash
ps -L -p "$APP_PIDS" -o pid,ppid,tid,stat,pcpu,pmem,rss,wchan:32,comm,args > /work/evidence/demo/deadlock/threads-before.txt
top -H -b -n 1 -p "$LEADER_PID" > /work/evidence/demo/deadlock/top-before.txt
```

관제 로그를 수집합니다.

```bash
./monitor.sh -n agent-leak-app-arm64 -i 1 -d 25 -o "$DEADLOCK_MONITOR_TMP"
```

다음 로그를 확인합니다.

```text
LOCK ACQUIRED: [Shared_Memory_A]
LOCK ACQUIRED: [Socket_Pool_B]
WAITING for [Socket_Pool_B]... (Status: BLOCKED)
WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

Deadlock 프로세스를 종료합니다.

```bash
pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
sleep 1
pkill -KILL -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true

{
  printf '%s\n' '=== APPLICATION LOG ==='
  awk '{print}' "$DEADLOCK_APP_TMP"
  printf '\n%s\n' '=== MONITOR LOG ==='
  awk '{print}' "$DEADLOCK_MONITOR_TMP"
} > /work/evidence/demo/deadlock/before.log

rm -f "$DEADLOCK_APP_TMP" "$DEADLOCK_MONITOR_TMP"
```

### 11. Deadlock 회피 확인

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
run_and_monitor /work/evidence/demo/deadlock/after.log 15
```

After 로그에서 다음 내용을 확인합니다.

```text
[Thread-A] Task Completed. (100%)
[Thread-B] Task Completed. (100%)
[Thread-C] Task Completed. (100%)
[Scheduler] All tasks completed.
```

### 12. 생성된 증거 확인

```bash
find /work/evidence/demo -type f | sort
```

호스트에서 프로젝트 폴더를 확인하면 같은 증거 파일이 생성되어 있습니다. 주요 파일은 다음과 같습니다.

```text
evidence/demo/oom/before.log
evidence/demo/oom/after.log
evidence/demo/cpu/before.log
evidence/demo/cpu/after.log
evidence/demo/deadlock/before.log
evidence/demo/deadlock/after.log
evidence/demo/deadlock/processes.txt
evidence/demo/deadlock/threads-before.txt
evidence/demo/deadlock/top-before.txt
```

프로젝트 리포트와 원문 증거를 확인합니다.

```bash
sed -n '1,220p' reports/oom.md
sed -n '1,220p' reports/cpu.md
sed -n '1,240p' reports/deadlock.md
```

### 13. 환경변수 활용 방법

이 프로젝트의 장애 시나리오는 다음 환경변수로 제어합니다.

| 환경변수 | 허용 범위 | 활용 목적 |
|---|---|---|
| `MEMORY_LIMIT` | 50~512MB | MemoryGuard 임계치 조정 |
| `CPU_MAX_OCCUPY` | 10~100% | CpuWorker Watchdog 제한 조정 |
| `MULTI_THREAD_ENABLE` | true/false | 멀티스레드 Deadlock 시나리오 선택 |

예를 들어 메모리 임계치를 낮춰 빠르게 OOM을 재현하려면 다음처럼 실행합니다.

```bash
export MEMORY_LIMIT=50
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=false
```

멀티스레드 Deadlock을 재현하려면 다음처럼 실행합니다.

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=30
export MULTI_THREAD_ENABLE=true
```

환경변수를 변경할 때마다 애플리케이션을 종료한 뒤 다시 시작해야 새 설정이 적용됩니다.

### 14. 종료 및 재시작

시연이 끝났을 때는 먼저 앱을 종료합니다.

```bash
pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
```

컨테이너에서 빠져나갑니다.

```bash
exit
```

컨테이너는 `--rm` 옵션으로 실행했기 때문에 종료 시 자동 삭제됩니다. 프로젝트 파일과 `evidence/demo`에 생성된 로그는 호스트 폴더에 남습니다. 다음에 다시 실행할 때는 Docker 실행 명령부터 반복하면 됩니다.

### 15. 문제 해결

#### `Exec format error`

ARM64 바이너리를 다른 아키텍처에서 직접 실행한 경우입니다. Docker 실행 명령에 다음 옵션이 있는지 확인합니다.

```text
--platform linux/arm64
```

#### `All Boot Checks Passed!`가 나오지 않는 경우

다음 파일을 확인합니다.

```bash
cat /work/boot-check.log
```

주요 원인은 다음과 같습니다.

- `AGENT_HOME` 등 환경변수 오타
- `secret.key` 파일 누락 또는 잘못된 내용
- `/tmp/agent_home` 권한 부족
- 이전 프로세스가 `15034` 포트를 점유
- root로 직접 애플리케이션을 실행함

이전 프로세스를 정리하고 다시 시작합니다.

```bash
pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
sleep 1
pkill -KILL -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
```

#### `ps`, `top`, `pgrep` 명령이 없는 경우

컨테이너 내부에서 다음을 실행합니다.

```bash
apt-get update
apt-get install -y procps psmisc
```

#### 같은 명령을 여러 번 실행한 경우

`[1] 253` 같은 메시지는 백그라운드 작업이 생성됐다는 뜻입니다. 같은 실행 명령을 반복하지 말고, 아래 명령으로 기존 프로세스를 정리한 뒤 로그를 확인합니다.

```bash
pkill -TERM -f '^/work/agent-leak-app-arm64$' 2>/dev/null || true
cat /work/boot-check.log
```

컨테이너 안의 `root@...:/work#` 프롬프트에서 `AGENT\_HOME`처럼 역슬래시가 포함된 변수명을 입력하면 안 됩니다. 반드시 `AGENT_HOME`처럼 입력해야 합니다.
