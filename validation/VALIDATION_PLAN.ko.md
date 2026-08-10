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
| `t1a-native-restore` | 네이티브 복원 경로에서 GPU 디바이스가 살아남음 | **C** (배관) | 미실행 |
| `t1b-fluidcr-app` | **실제 애플리케이션 레벨 C/R** + 학습 step 재개 | **B** | 미실행 |
| `t4-dispatch` | 두 Pod가 각자 경로로 가고 교차하지 않음 | **C** (완성) | 미실행 |
| `t2-crossnode-system` | staging 으로 다른 노드에서 복원 | 추가 | 미실행 |

**현재 A와 D만 채워져 있습니다.** B가 비어 있는 한 "통합"은 절반만 증명된 상태입니다.

---

## 2. t1a 와 t1b 는 다른 것을 증명한다

이 구분이 이 문서의 핵심입니다.

### t1a — CRI-O 배관 검사

평범한 CUDA 컨테이너를 kubelet checkpoint API 로 뜨고,
`checkpoint-restore.crio.io/<container>` 로 복원한다.

| | |
|---|---|
| **증명하는 것** | `CRImportCheckpointFromPath` 경로가 병합 후에도 살아 있다. 그 경로에서 복원된 컨테이너가 `/dev/nvidia*` 를 받는다 (②CDI 가드가 이 경로를 망가뜨리지 않았다) |
| **증명하지 못하는 것** | **애플리케이션 레벨 체크포인트는 일어나지 않는다.** `state_dict` 도, SIGUSR1 도, launcher 도 없다. CRIU 가 컨테이너를 통째로 뜬 것뿐이고 애플리케이션은 자기가 체크포인트된 줄도 모른다 |
| 비용 | 낮음. FluidCR·`leehun-criu` 불필요 |

**t1a 는 조각 B 를 채우지 않습니다.** C 의 절반(배관)만 채웁니다.

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
(다음)  t1a-native-restore     ← 싸고 빠름. C 배관 확인
        t1b-fluidcr-app        ← B. 발표 주장에 필요한 것
        t4-dispatch            ← C 완성. t1a 또는 t1b 산출물 사용
        t2-crossnode-system    ← 추가 기여
```

t1a 를 먼저 하는 이유는 단순합니다. 싸고, t1b 가 실패했을 때 **원인이 CRI-O 배관인지
FluidCR 자체인지 가르는 대조군**이 되기 때문입니다.

- t1a 통과 + t1b 실패 → CRI-O 는 멀쩡. FluidCR 쪽 문제 (스톡 CRIU 등)
- t1a 실패 → 배관부터 깨져 있음. t1b 는 볼 것도 없음

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
