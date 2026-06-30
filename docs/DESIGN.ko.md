# 설계 — K8s-Native GPU Restore (CRI-O)

체크포인트 시스템(`K8s-Native-Fast-GPU-Checkpoint-Restore-System`)이 만든
`Checkpoint.tar`를, 임의의 노드에서 **새 Pod로 복원**하는 경로를 CRI-O 런타임
핸들러로 구현한다. 체크포인트 파이프라인의 정확한 역순 미러다.

## 트리거 — annotation 기반 + 커스텀 RuntimeClass

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restore-vllm
  annotations:
    gpu-cr.io/restore: "true"
    gpu-cr.io/checkpoint-uri: "<scheme>://<location>/<path>"
    gpu-cr.io/source-pod-uid: "<원본 Pod UID>"
spec:
  runtimeClassName: gpu-cr-restore
  nodeSelector:
    kubernetes.io/hostname: gpu-node-2
  containers:
    - name: vllm
      image: <checkpoint와 호환되는 이미지>
      resources:
        limits:
          nvidia.com/gpu: 1
```

`runtimeClassName: gpu-cr-restore` → CRI-O의 `gpu-cr-restore` 핸들러 → 우리 shim
(`/usr/local/bin/gpu-cr-restore-shim`)이 OCI 런타임으로 호출됨. shim은 `create`
이외의 모든 verb를 실제 `crun`으로 그대로 패스스루하고, **restore annotation이 붙은
create만** 복원 파이프라인으로 분기한다.

## 전체 흐름 (보완된 8단계)

| 단계 | 주체 | 동작 |
|---|---|---|
| 1 | 사용자 | Restore Pod yaml apply |
| 2 | 스케줄러 | target 노드 선택 (실험: `nodeSelector`로 명시) |
| **2.5** | **shim (stage)** | **`checkpoint-uri`의 tar를 target 노드로 staging + unpack** |
| **2.6** | device plugin | `nvidia.com/gpu` 할당 + `/dev/nvidia*` — CRIU 복원 전에 완료 |
| 3 | kubelet | CRI-O(`gpu-cr-restore` 핸들러) 호출 |
| 4 | shim → crun | **CRIU**로 컨테이너/CPU 프로세스 복원 (host 상주 GPU 제어상태·데이터버퍼가 평범한 프로세스 메모리로 함께 복귀) |
| 5 | shim → host helper | **GPU 제어상태 복원**: `cuda-checkpoint --action restore` (contexts/streams를 device에 재설치) |
| 6 | shim → interceptor | **GPU 데이터버퍼 복원**: 동일 VA로 remap + H2D |
| 7 | 복원된 프로세스 | workload resume |
| 8 | CRI-O/kubelet | 정상 Running 컨테이너로 등록 |

## 왜 이 순서가 안전한가

체크포인트는 **CUDA suspended 상태**(cuda-checkpoint가 제어상태를 host로 evict)에서
떠졌다. 따라서 CRIU 복원 직후 프로세스는 실행 상태지만 **다음 CUDA 호출이 block**된다 —
제어상태가 복원되기 전까지. 이 window 안에서 (5) 제어상태 복원 → (6) 데이터버퍼를 **동일
VA**에 remap(H2D)하면, (7) 앱의 CUDA 호출이 유효한 device 포인터로 unblock된다.

핵심 불변식(체크포인트 측과 동일): **VA는 절대 해제되지 않았으므로** 같은 주소로 remap이
성립하고, 복원된 CPU 메모리 안의 GPU 포인터가 그대로 유효하다.

## staging — "노드 간 복원"을 명시적 단계로

CRI-O를 변경/감싸 staging을 1급 단계로 넣었다(`runtime/lib/stage.sh`). 지원 scheme:

- `file://`, `hostpath://` — 노드에 이미 있는 파일(같은 노드 복원/사전 staging)
- `nfs://` — export를 ro 마운트 후 복사
- `http(s)://` — proxy 통해 pull
- `s3://` — stub (외부 uploader로 사전 staging 후 `file://` 사용)

같은 노드면 `/var/lib/gcr-checkpoint`에 이미 있어 로컬 복사로 끝나고, 다른 노드로
migration하면 이 단계가 tar를 target 노드로 가져온다.

## GPU 단계의 통합 지점 (체크포인트 측 재사용)

- **(5) 제어상태**: in-container `cuda-checkpoint`는 glibc ABI 불일치로 stack-smash 하므로,
  체크포인트 측과 동일하게 **host helper service(`gpu-cr-cuda-helper.service`)**에 위임한다.
  shim은 `restore <pid>` 요청 파일을 쓰고 응답을 폴링한다.
- **(6) 데이터버퍼**: in-Pod 인터셉터(`libgcr-interceptor.so`)에 `GCR_RESTORE(2)` 신호를
  control 채널로 보낸다. **CRIU가 원본 env를 복원**하므로 인터셉터는 원본 `GCR_POD_UID`
  경로를 watch한다 → shim은 `gpu-cr.io/source-pod-uid`로 그 키에 신호한다.

## 가능성 판단 / 미검증 지점 (정직하게)

1. **create→restore 변환의 CRI-O 라이프사이클 정합성**: shim은 `create`에서 `crun restore`를
   수행하고 marker를 남겨 후속 `start`를 ack한다. CRI-O 버전별 create/start 계약 차이는
   실측 필요(검증 노드: K8s v1.33 + CRI-O v1.33).
2. **source-pod-uid 의존**: 데이터 remap이 원본 UID 키에 의존. 체크포인트 시 tar에 메타로
   원본 UID를 같이 저장하면 annotation 없이 자동화 가능(후속).
3. **이미지 호환성**: 복원 rootfs는 체크포인트 이미지와 호환되어야 함.
4. **device plugin 선행**: `nvidia.com/gpu` 할당과 `/dev/nvidia*`가 CRIU 복원 시점에 준비돼
   있어야 device fd 재오픈이 성립.
5. **단일 컨테이너/단일 GPU** 기준. 멀티프로세스(NCCL)·멀티GPU는 후속.

## 검증 전략

`sample-restore-pod-l1.yaml`로 체크섬 워크로드를 복원해, 복원 후 GPU 텐서 체크섬이
체크포인트 시점과 **동일**한지로 end-to-end(제어상태+데이터) 정합성을 확인한다.
