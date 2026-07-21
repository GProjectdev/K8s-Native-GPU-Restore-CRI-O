# K8s-Native-GPU-Restore-CRI-O

체크포인트 시스템
([K8s-Native-Fast-GPU-Checkpoint-Restore-System](https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System))이
만든 `Checkpoint.tar`를 새 Pod로 **복원**하는 Custom CRI-O. CRI-O의 **네이티브 복원 경로를
최소 패치**한 방식이다(cri-o 포크
[`leehun-cri-o`](https://github.com/lehuannhatrang/leehun-cri-o)와 같은 방향) + GPU 단계용
OCI hook.

> 사용법: [docs/USAGE.ko.md](docs/USAGE.ko.md) · 노드간: [docs/MIGRATION.ko.md](docs/MIGRATION.ko.md) · 설계/비교: [docs/DESIGN.ko.md](docs/DESIGN.ko.md) · 실험: [docs/SETUP.ko.md](docs/SETUP.ko.md)

## 왜 shim이 아니라 CRI-O 포크인가

CRI-O는 컨테이너 `image`가 노드의 로컬 체크포인트 아카이브이면 **네이티브로 복원**한다
(`CreateContainer` → "Assuming it is a checkpoint archive" → `CRImportCheckpoint`/CRIU).
이 경로는 conmon·sandbox·kubelet 상태를 정확히 처리한다. 그래서 `create`를 가로채는 shim
대신, 네이티브 경로에 부족한 **staging** 하나만 더하고 GPU 작업은 poststart hook에서 한다.
CRI-O 재빌드가 어려운 환경을 위한 shim 대안은 [`alt-shim/`](alt-shim/)에 보존했다.

## 패치가 더하는 것

```
crio-patch/server/gpu_cr_restore.go            # stageGPUCheckpoint(): checkpoint-uri를
                                                # 노드로 staging, image를 로컬 tar로 치환
crio-patch/0001-create-stage-gpu-checkpoint.patch  # CreateContainer에 호출 1줄
                                                # (cri-o v1.33.x 대상; 빌드 기본값 v1.33.13)
oci-hooks/ + hooks/                             # poststart hook + restore-agent:
                                                # GPU 데이터버퍼 remap (제어상태는
                                                # CRIUgpu로 복귀)
```

## 복원 흐름

```
1  Restore Pod yaml apply  (image = 체크포인트 아카이브 경로)
2  스케줄러가 노드 선택      (실험: nodeSelector)
2.5 Custom CRI-O가 두 파일을 노드로 STAGING
      - 체크포인트 .tar (CPU + GPU 제어상태)     -> 컨테이너 이미지
      - 형제 .blob (GPU 메모리 데이터)           -> /var/lib/gcr-data/<uid>/data.blob
3  kubelet -> CRI-O 로컬 아카이브 감지
4  CRIU 복원 + cuda_plugin   (컨테이너 + CPU 프로세스 + GPU 제어상태 — CRIUgpu)
5  restore-agent가 복원된 컨테이너 감지 (gpu-cr.io/restore=true)
6  데이터 remap: 인터셉터가 .blob 재오픈 후 physical 재생성 + 동일 VA + H2D
7  gate에 대기하던 커널 런치 unblock -> workload resume
8  CRI-O/kubelet이 정상 Running 컨테이너로 등록
```

## 빠른 시작

```bash
./hack/build-crio.sh
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$(command -v crio)"
sudo ./scripts/install-node.sh
kubectl apply -f deploy/sample-restore-pod-l1.yaml   # placeholder 채운 뒤
```

전체 절차: [docs/SETUP.ko.md](docs/SETUP.ko.md).

## 상태

실험용, 단일 컨테이너·단일 GPU. **cri-o v1.33.13(K8s v1.33, NVIDIA 570.211.01, A100)에서
end-to-end 검증 완료:** 같은 노드 복원과 노드 간 마이그레이션(worker-1 → worker-2, HTTP로
체크포인트 pull) 모두 워크로드가 재개되고 GPU 체크섬이 비트 단위로 일치하며, restore-agent로
`kubectl apply`만으로 완전 자동 동작. 패치(0001–0004)는 cri-o **v1.33.x** 기준(빌드 기본값 v1.33.13, worker에서 end-to-end 검증). 다른 마이너 버전이면 앵커 rebase 필요.
전제·남은 지점은 [docs/DESIGN.ko.md](docs/DESIGN.ko.md), 노드 간 절차는
[docs/MIGRATION.ko.md](docs/MIGRATION.ko.md).

## 함정 (실측으로 배운 것)

- **노드가 도는 CRI-O 버전으로 빌드**하라(`crio --version` → `CRIO_VERSION=v1.33.x`). 패치 앵커는
  1.33 계열 기준이라 다른 버전은 rebase가 필요할 수 있다.
- 모든 노드에 **crun ≥ 1.9**.
- **소켓 없는 깨끗한 체크포인트.** 체크포인트 시점에 TCP 소켓을 물고 있으면
  (`CRIU -52 / Need to set the --tcp-close options`) 복원이 실패한다 — CRI-O/crun이 복원 시
  `tcp-close`를 안 넘기기 때문. 워크로드를 오프라인으로(예: 모델을 로컬 경로에서 로드,
  `HF_HUB_OFFLINE=1`) 만들고 소스 노드 `/etc/criu/default.conf`에서 `tcp-close`를 제거하라.
  자세히는 docs/SETUP.ko.md §7.
- **모델 파일**은 소스·복원 노드에 **동일 경로로 마운트**된 위치에서 로드하라.
