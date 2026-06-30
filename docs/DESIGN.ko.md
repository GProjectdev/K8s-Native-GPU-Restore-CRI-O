# 설계 — K8s-Native GPU Restore (Custom CRI-O)

체크포인트 시스템(`K8s-Native-Fast-GPU-Checkpoint-Restore-System`)이 만든
`Checkpoint.tar`를 임의의 노드에서 **새 Pod로 복원**한다. CRI-O의 **네이티브 복원
경로를 최소 패치**해서 구현한다(`lehuannhatrang/leehun-cri-o`가 cri-o 포크인 것과 같은
방향).

## 왜 "shim"이 아니라 "CRI-O 포크"인가

| | CRI-O 포크 (채택) | 런타임 shim (대안, `alt-shim/`) |
|---|---|---|
| 복원 실행 | CRI-O의 **네이티브** `CRImportCheckpoint`(CRIU) 사용 | shim이 `create`를 가로채 `crun restore`로 변환 |
| conmon/sandbox/상태 | CRI-O가 정상 처리 | shim이 CRI-O 뒤에서 처리 → 버전별 불일치 위험 |
| 변경량 | server에 staging 함수 1개 + 호출 1줄 + poststart hook | crun 래퍼 + verb 프록시 |
| 시스템 정합성 | repo 명칭("Custom CRI-O") · 참고 포크와 일치 | 빠른 실험용 |

체크포인트 측이 CRI-O를 포크하지 않고 kubelet checkpoint API를 쓴 것과 달리, **복원은
kubelet에 대응 API가 없고** 런타임 레벨 통합이 필요하다. CRI-O는 이미 견고한 복원 경로를
갖고 있으므로, 그걸 재구현(shim)하기보다 **그 경로에 staging만 더하는 최소 포크**가 가장
적합하다. GPU 단계는 체크포인트 측과 동일하게 host helper + 인터셉터에 위임한다.

## CRI-O가 복원으로 분기하는 조건 (포크의 근거)

`server/container_create.go`의 `CreateContainer`는 컨테이너 `image`가 **노드의 로컬 파일이면
체크포인트 아카이브로 간주**하고 `CRImportCheckpoint`(CRIU 복원)로 분기한다:

```go
if _, err := os.Stat(req.GetConfig().GetImage().GetImage()); err == nil {
    // "Assuming it is a checkpoint archive" → 네이티브 복원
}
```

따라서 우리가 할 일은 단 하나: **복원 직전에 `checkpoint-uri`의 tar를 노드로 staging하고
image를 그 로컬 경로로 바꿔** 위 감지가 성립하게 만드는 것.

## 패치 (crio-patch/)

- **`server/gpu_cr_restore.go`** (새 파일): `stageGPUCheckpoint(ctx, cfg)` —
  `gpu-cr.io/restore=true`면 `gpu-cr.io/checkpoint-uri`를 노드로 staging
  (file/hostpath/nfs/https) 후 `cfg.Image`를 로컬 아카이브 경로로 교체. 아니면 no-op.
- **`0001-create-stage-gpu-checkpoint.patch`**: `CreateContainer` 최상단(체크포인트 감지
  직전)에 `s.stageGPUCheckpoint(...)` 호출 1줄 삽입. cri-o **v1.35.0**에 clean apply 확인.

## GPU 복원 = OCI poststart hook (oci-hooks/, hooks/)

CRIU가 CPU 프로세스를 복원하면(이때 host 상주 GPU 제어상태·데이터버퍼가 평범한 프로세스
메모리로 함께 복귀), CRI-O가 등록한 **poststart hook**(`gpu-cr.io/restore=true` 매칭)이:

1. **(5) 제어상태 복원** — `cuda-checkpoint --action restore`를 host helper
   (`gpu-cr-cuda-helper.service`)에 위임(in-container 실행은 glibc ABI로 stack-smash).
2. **(6) 데이터버퍼 remap** — in-Pod 인터셉터에 `GCR_RESTORE(2)` 신호를 control 채널로 전송.
   **CRIU가 원본 env를 복원**하므로 인터셉터는 원본 `GCR_POD_UID` 경로를 watch →
   `gpu-cr.io/source-pod-uid`로 그 키에 신호.

## 왜 이 순서가 안전한가

체크포인트는 **CUDA suspended 상태**에서 떠졌으므로, CRIU 복원 직후 프로세스의 다음 CUDA
호출은 제어상태가 복원될 때까지 **block**된다. 이 window에서 (5)→(6)을 끝내면 (7) 앱이 유효한
device 포인터로 unblock된다. **VA는 한 번도 해제되지 않았으므로** 같은 주소 remap이 성립한다.

## 전체 흐름 (8단계)

| 단계 | 주체 | 동작 |
|---|---|---|
| 1 | 사용자 | Restore Pod yaml apply (image = 체크포인트 아카이브 경로) |
| 2 | 스케줄러 | target 노드 선택 (실험: `nodeSelector`) |
| **2.5** | **Custom CRI-O (patch)** | `checkpoint-uri`의 tar를 노드로 staging + image 경로 치환 |
| 2.6 | device plugin | `nvidia.com/gpu` 할당 / `/dev/nvidia*` |
| 3 | kubelet → CRI-O | 로컬 아카이브 감지 → 네이티브 복원 분기 |
| 4 | CRI-O/CRIU | 컨테이너 + CPU 프로세스 복원 |
| 5 | poststart hook → host helper | GPU 제어상태 복원 |
| 6 | poststart hook → interceptor | GPU 데이터버퍼 remap (동일 VA + H2D) |
| 7 | 복원된 프로세스 | workload resume |
| 8 | CRI-O/kubelet | 정상 Running 컨테이너로 등록 |

## 가능성 판단 / 미검증 지점 (정직하게)

1. **컴파일 미검증**: 이 환경엔 Go 툴체인이 없어 `gpu_cr_restore.go`와 patch는 **빌드/실측
   미검증**이다. `hack/build-crio.sh`로 cri-o v1.35.0에 적용해 빌드해야 한다. patch의 clean
   apply만 확인됨.
2. **CRI-O 버전**: patch는 v1.35.0 기준. 다른 버전이면 `CreateContainer` 앵커를 rebase.
3. **source-pod-uid 의존**: 데이터 remap이 원본 UID 키에 의존. 체크포인트 tar에 원본 UID를
   메타로 저장하면 annotation 없이 자동화 가능(후속).
4. **이미지/rootfs 호환성**, **device plugin 선행**: CRIU 복원 시점에 GPU 디바이스 접근이
   준비돼 있어야 함.
5. **단일 컨테이너/단일 GPU** 기준. 멀티프로세스(NCCL)·멀티GPU는 후속.

## 검증 전략

`deploy/sample-restore-pod-l1.yaml`로 체크섬 워크로드를 복원해, 복원 후 GPU 텐서 체크섬이
체크포인트 시점과 **동일**한지로 end-to-end 정합성을 확인한다.
