# K8s-Native-GPU-Restore-CRI-O

체크포인트 시스템
([K8s-Native-Fast-GPU-Checkpoint-Restore-System](https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System))이
만든 `Checkpoint.tar`를 새 Pod로 **복원**하는 Custom CRI-O. CRI-O의 **네이티브 복원 경로를
최소 패치**한 방식이다(cri-o 포크
[`leehun-cri-o`](https://github.com/lehuannhatrang/leehun-cri-o)와 같은 방향) + GPU 단계용
OCI hook.

> 설계/비교: [docs/DESIGN.ko.md](docs/DESIGN.ko.md) · 실험: [docs/SETUP.ko.md](docs/SETUP.ko.md)

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
                                                # (cri-o v1.35.0에 clean apply 확인)
oci-hooks/ + hooks/                             # poststart hook: GPU 제어상태 복원
                                                # + 데이터버퍼 remap
```

## 복원 흐름

```
1  Restore Pod yaml apply  (image = 체크포인트 아카이브 경로)
2  스케줄러가 노드 선택      (실험: nodeSelector)
2.5 Custom CRI-O가 checkpoint-uri의 tar를 노드로 STAGING
3  kubelet -> CRI-O 로컬 아카이브 감지
4  CRIU 복원               (컨테이너 + CPU 프로세스)
5  poststart hook: GPU 제어상태  (cuda-checkpoint --restore via host helper)
6  poststart hook: GPU 데이터버퍼 (인터셉터 동일 VA remap + H2D)
7  workload resume
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

실험용, 단일 컨테이너·단일 GPU. patch는 cri-o v1.35.0에 clean apply되지만 **빌드/실측은
미검증**(작성 환경에 Go 툴체인 없음). 정직한 미검증 지점은
[docs/DESIGN.ko.md](docs/DESIGN.ko.md).
