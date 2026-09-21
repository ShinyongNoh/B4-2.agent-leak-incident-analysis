# Evidence index

리포트에서 인용한 최종 증거 파일은 아래와 같습니다. 같은 디렉터리의 `*-before.log`, `*-after.log` 중 `-final` 또는 리포트에 직접 링크된 파일을 제출 기준으로 사용합니다.

| Case | Application logs | Monitor / system evidence |
|---|---|---|
| OOM | `oom/app-before-final.log`, `oom/app-after-final.log` | `oom/monitor-before-final.log`, `oom/monitor-after-final.log` |
| CPU | `cpu/app-baseline-final.log`, `cpu/app-after-long.log` | `cpu/monitor-baseline-final.log`, `cpu/monitor-after-long.log` |
| Deadlock | `deadlock/app-final.log`, `deadlock/app-after.log` | `deadlock/monitor-final.log`, `deadlock/ps-ef-final.txt`, `deadlock/threads-final.txt`, `deadlock/threads-final-after.txt`, `deadlock/top-final.txt`, `deadlock/top-final-after.txt` |

CPU 케이스의 `CpuWorker Current Load`는 애플리케이션 내부 Watchdog 지표이고, `monitor.sh`의 `ps` CPU는 Linux host 관측값입니다. 두 값이 달랐으므로 리포트에서 별도 계측으로 명시했습니다.
