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

`monitor.sh`는 바이너리가 fork하는 프로세스를 고려해 일치하는 프로세스들의 CPU, MEM, RSS, 스레드 수를 합산하고, 종료 시점 또는 관측 시간 종료도 로그로 남깁니다.

## 검증 요약

| Case | Before | After / 결과 |
|---|---|---|
| OOM | `MEMORY_LIMIT=50`: 약 5초 후 `MemoryGuard` 종료 | `MEMORY_LIMIT=512`: 35초 관측 동안 생존, RSS 약 18MB → 300MB |
| CPU | `CPU_MAX_OCCUPY=30`: 30%에서 cooldown, 30초 관측 생존 | `CPU_MAX_OCCUPY=100`: 내부 부하 54.08%에서 `CPU Threshold Violated` 후 종료 |
| Deadlock | `MULTI_THREAD_ENABLE=true`: 두 자원에 대한 순환 대기, 25초 동안 무응답 | `false`: `Thread-A/B/C` 작업 완료 및 정상 모니터링 진행 |