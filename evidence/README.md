# Evidence index

리포트에서 인용한 최종 증거 파일은 각 장애 유형별 `before.log`와 `after.log`입니다. 각 파일 안에 애플리케이션 로그와 `monitor.sh` 관제 로그가 구역별로 함께 들어 있습니다.

| Case | Combined before/after logs | Monitor / system evidence |
|---|---|---|
| OOM | `oom/before.log`, `oom/after.log` | combined logs 내부의 `MONITOR LOG` 구역 |
| CPU | `cpu/before.log`, `cpu/after.log` | combined logs 내부의 `MONITOR LOG` 구역 |
| Deadlock | `deadlock/before.log`, `deadlock/after.log` | `deadlock/ps-before.txt`, `deadlock/ps-after.txt`, `deadlock/threads-before.txt`, `deadlock/threads-after.txt`, `deadlock/top-before.txt`, `deadlock/top-after.txt` |

CPU 케이스의 `CpuWorker Current Load`는 애플리케이션 내부 Watchdog 지표이고, `monitor.sh`의 `ps` CPU는 Linux host 관측값입니다. 두 값이 달랐으므로 리포트에서 별도 계측으로 명시했습니다.
