# 검증 계획 — 무엇을 증명하려는가

최종 갱신: 2026-08-10

## 0. 증명 대상

Progress Report의 핵심 주장은 하나입니다.

> 시스템 레벨(GCR/CRIUgpu)과 애플리케이션 레벨(FluidCR) GPU Checkpoint/Restore를
> **하나의 CRI-O 바이너리에서 통합**했다.

이걸 검사 가능한 네 조각으로 쪼갭니다.

| | 조각 |
|---|---|
| **A** | system 경로가 **값까지 정확히** 동작한다 |
| **B** | application 경로가 동작한다 |
| **C** | 두 경로가 서로 간섭하지 않는다 |
| **D** | C/R과 무관한 워크로드는 영향받지 않는다 |

네 조각이 모두 채워져야 "통합했다"가 성립합니다.

---

## 1. 테스트 ↔ 주장 대응

| 테스트 | 정확히 무엇을 확인하는가 | 조각 | 상태 |
|---|---|---|---|
| `00-preflight` | 노드가 CRIUgpu 구성인가 (전제 확인) | — | ✅ 완료 |
| `t3-isolation` | annotation 없는 GPU Pod에 staging이 끼어들지 않음 | **D** | ✅ 완료 |
| `t0-checksum` | system C/R 후 GPU 텐서가 바이트 단위 동일 | **A** | ✅ 완료 |
| `t1a-native-restore` | (선택) 네이티브 진입점이 도달 가능한가 — **t1b 실패 시 진단용** | — | 선택 |
| `t1b-fluidcr-app` | **실제 애플리케이션 레벨 C/R** + 학습 step 재개 | **B** | ✅ 완료 (step 1260 재개) |
| `t4-dispatch` | 두 Pod가 각자 경로로 가고 교차하지 않음 | **C** (완성) | ✅ 완료 (7/7) |
| `t2-crossnode-system` | staging 으로 다른 노드에서 복원 | 추가 | 미실행 |

**A · B · C · D 네 조각이 모두 채워졌습니다 (2026-08-10).**

t4 실행 결과 `results/20260810-083716-t4-dispatch/dispatch.log`:

- system Pod → `gpu-cr: restore annotation detected` → `staged checkpoint` → `staged GPU data blob`
- application Pod → 컨테이너 생성됨. **`gpu-cr:` 줄이 하나도 붙지 않음** (교차 없음)
- 둘 다 같은 노드(`jsj-worker-1`)의 **같은 CRI-O 프로세스**(`crio[566]`)에서, **동시에** Running

> 실제로 돈 스크립트는 두 Pod을 동시에 띄우는 버전이었고, worker-1 의 GPU 가 2장
> 이상이라 둘 다 스케줄됐습니다. 순차 실행보다 강한 결과이므로 이 로그를 그대로
> 씁니다.

부수적으로 확인된 것 (계획에 없던 소득):

| | |
|---|---|
| `staged GPU data blob → /var/lib/gcr-data/<uid>/data.blob` | **`data.blob` 도 staging 된다.** t2 의 구멍이라고 적어둔 것은 틀렸음 |
| `gpu-cr: ext-mount-map` 4줄 (StartContainer) | ⑤ `buildGCRExtMountMapLines()` 동작 확인 |
| blob 경로에 source-pod-uid 가 박혀 있음 | ③ annotation 전파 동작 확인 |

`t0-checksum` 은 `CRImportCheckpoint` → `buildContainerConfig` 를 통과했고, 그 안에
②CDI 가드가 있습니다. **체크섬이 맞았다는 것 자체가 GPU 디바이스가 정상 주입됐다는
증거**입니다 — 디바이스가 없었다면 `remap: 4 segs ... 0 failed` 이 나올 수 없습니다.

따라서 남은 것은 **B (t1b)** 와 **C 의 나머지 — 두 진입점이 실제로 공존하고 교차하지
않는가 (t4)** 둘뿐입니다.

---

## 2. t1a 와 t1b 는 다른 것을 증명한다

이 구분이 이 문서의 핵심입니다.

### t1a — 진단용 (필수 아님)

평범한 CUDA 컨테이너를 kubelet checkpoint API 로 뜨고,
`checkpoint-restore.crio.io/<container>` 로 복원한다.

| | |
|---|---|
| **증명하는 것** | `CRImportCheckpointFromPath` 경로가 병합 후에도 살아 있다. 그 경로에서 복원된 컨테이너가 `/dev/nvidia*` 를 받는다 (②CDI 가드가 이 경로를 망가뜨리지 않았다) |
| **증명하지 못하는 것** | **애플리케이션 레벨 체크포인트는 일어나지 않는다.** `state_dict` 도, SIGUSR1 도, launcher 도 없다. CRIU 가 컨테이너를 통째로 뜬 것뿐이고 애플리케이션은 자기가 체크포인트된 줄도 모른다 |
| 비용 | 낮음. FluidCR·`leehun-criu` 불필요 |

**t1a 는 필수가 아닙니다.** `buildContainerConfig` 의 디바이스 처리는 t0 가 이미
통과시켰고(호출자만 다를 뿐 가드는 `GetCDIDevices()` 만 보므로 동작이 동일),
"두 번째 진입점이 도달 가능한가" 는 t4 가 확인합니다.

남겨두는 이유는 하나뿐입니다 — **t1b 가 실패했을 때 원인을 가르는 대조군**.

- t1a 통과 + t1b 실패 → CRI-O 배관은 멀쩡. FluidCR 쪽 문제 (스톡 CRIU 등)
- t1a 실패 → 배관부터 깨져 있음. t1b 는 볼 것도 없음

### t1b — 실제 애플리케이션 레벨 C/R

FluidCR 을 실제로 설치해 돌린다.

| | |
|---|---|
| **증명하는 것** | 애플리케이션이 SIGUSR1 을 받아 학습 루프를 멈추고 `state_dict` 를 저장한다. 복원 후 **체크포인트된 step 부터 학습이 이어진다** |
| 비용 | 중간. `pip install fluidcr` 로 설치. 실패 가능성 있음 |
| 실패해도 가치 | 스톡 CRIU 로는 부족하다는 **근거**가 됨 |

**t1b 가 조각 B 를 채웁니다.** 발표 주장에 실제로 필요한 것은 이쪽입니다.

---

## 3. t1b 상세 — 무엇을 어떻게

### FluidCR 이 하는 일 (상류 README 기준)

```
fluidcr-launcher python -u train.py
    │
    ├─ launcher: train.py 를 자식 프로세스로 spawn
    │            PYTHONPATH 로 sitecustomize.py 주입
    │            컨테이너 안에 REST 서버 기동 (0.0.0.0:8298)
    │
    └─ payload:  torch 에 PEP-451 import hook 설치
                 nn.Module / optim.Optimizer 를 monkey-patch 해 추적
                 builtins.enumerate 를 patch → DataLoader 재개 지점 기억
                 SIGUSR1 수신 시 state_dict 저장 후 exit 99
```

체크포인트 트리거:

```bash
kubectl exec <pod> -- fluidcr-ctrl checkpoint --all
# 내부적으로: SIGUSR1 → worker 저장 후 exit 99
#             → launcher 가 /checkpoint/<PID>/latest.pt 를 RAM 에 버퍼링
#             → /checkpoint/<PID>/lock 생성 (스냅샷 준비 완료 신호)
```

### 6단계

| 단계 | 동작 | 이 단계가 증명하는 것 |
|---|---|---|
| 1 | pytorch Pod + `pip install fluidcr` + `fluidcr-launcher python train.py` | 설치·기동 |
| 2 | 학습이 돌면서 `epoch N step M` 출력 | 베이스라인 |
| 3 | `fluidcr-ctrl checkpoint --all` | **애플리케이션 레벨 체크포인트** ← 조각 B 의 핵심 |
| 4 | `/checkpoint/<PID>/lock` 존재 확인 | 저장 완료 |
| 5 | kubelet checkpoint API → tar, 원본 삭제 | 컨테이너 스냅샷 |
| 6 | `checkpoint-restore.crio.io/<c>` 로 복원 | 복원 |
| **7** | **학습이 체크포인트된 step 부터 재개되는지** | **최종 판정** |

### 판정 기준

FluidCR 예제의 `train.py` 는 평범한 PyTorch 루프입니다.

```python
for step, (x, y) in enumerate(loader):
    ...
    if step % 50 == 0:
        print(f"epoch {epoch} step {step} loss {loss.item():.4f}")
```

FluidCR 이 `enumerate()` 를 patch 하므로, 복원 후에도 **같은 step 번호에서 이어져야**
합니다.

| 복원 후 로그 | 판정 |
|---|---|
| `epoch 0 step 0` 부터 다시 | ❌ 애플리케이션 상태가 복원되지 않음 |
| 체크포인트 시점의 step 부터 이어감 | ✅ **조각 B 확정** |

이 한 줄이 t0 의 체크섬에 대응하는 증거입니다.

---

## 4. 실행 순서

```
(완료) 00-preflight  →  t3-isolation  →  t0-checksum
(다음)  t1b-fluidcr-app        ← B. 유일하게 비어 있는 조각
        t4-dispatch            ← C 완성. t1b 산출물 사용
        t2-crossnode-system    ← 추가 기여

(선택)  t1a-native-restore     ← t1b 가 실패했을 때만
```

**t4 는 t1b 의 체크포인트를 쓰는 것이 중요합니다.** t1a 것을 쓰면 t4 가 증명하는 것이
"CRI-O 진입점 두 개" 로 약해지고, t1b 것을 쓰면 **"모드 두 개"** 가 됩니다.

---

## 5. 알려진 불확실성

**FluidCR 이 `leehun-criu` 포크를 요구한다.** 이 클러스터는 스톡
`criu 4.2.1-1ppa1.22.04` 입니다.

다만 FluidCR 은 CRIU 덤프 **전에** GPU 를 teardown 하므로, 덤프 시점에는 GPU 상태가
없습니다. 체크포인트 크기가 CRIUgpu 대비 63% 작은 이유가 그것입니다. 그렇다면 스톡
CRIU 로도 될 가능성이 있습니다. **가정하지 말고 t1b 로 확인합니다.**

**FluidCR 예제는 DRA + `runtimeClassName: nvidia-cdi` 를 쓴다.** 이 클러스터는 stock
device plugin + envvar 전략입니다. t1b 는 예제를 그대로 쓰지 않고 이 클러스터 구성에
맞춘 Pod 을 씁니다.
