# K8s-Native-GPU-Restore-CRI-O

체크포인트 시스템
([K8s-Native-Fast-GPU-Checkpoint-Restore-System](https://github.com/GProjectdev/K8s-Native-Fast-GPU-Checkpoint-Restore-System))이
만든 `Checkpoint.tar`를 새 Pod로 **복원**하는 커스텀 CRI-O 런타임 핸들러.
체크포인트 파이프라인의 정확한 역순이다.

> 설계: [docs/DESIGN.ko.md](docs/DESIGN.ko.md) · 실험 가이드: [docs/SETUP.ko.md](docs/SETUP.ko.md)

## 동작 방식

Pod가 annotation으로 복원을 선언한다:

```yaml
metadata:
  annotations:
    gpu-cr.io/restore: "true"
    gpu-cr.io/checkpoint-uri: "hostpath:///var/lib/gcr-checkpoint/Checkpoint.tar"
    gpu-cr.io/source-pod-uid: "<원본 pod uid>"
spec:
  runtimeClassName: gpu-cr-restore
  nodeSelector: { kubernetes.io/hostname: gpu-node-2 }
  containers:
    - { name: vllm, image: <체크포인트 호환 이미지>, resources: { limits: { nvidia.com/gpu: 1 } } }
```

`runtimeClassName: gpu-cr-restore` → CRI-O의 `gpu-cr-restore` 핸들러 → 우리 shim
(`crun` 래퍼). 모든 OCI verb는 `crun`으로 패스스루하고, **restore annotation이 붙은
`create`만** 복원 파이프라인으로 분기한다:

```
1  Restore Pod yaml apply
2  스케줄러가 target 노드 선택      (실험: nodeSelector)
2.5 shim이 Checkpoint.tar를 노드로 STAGING   (file/hostpath/nfs/https)
3  kubelet -> CRI-O (gpu-cr-restore 핸들러)
4  crun restore   — CRIU로 컨테이너 + CPU 프로세스 복원
5  GPU 제어상태   — cuda-checkpoint --restore (host helper)
6  GPU 데이터버퍼 — 인터셉터가 동일 VA로 remap + H2D
7  workload resume
8  CRI-O/kubelet이 정상 Running 컨테이너로 등록
```

체크포인트가 CUDA suspended 상태에서 떠졌으므로, CRIU 복원 직후 프로세스는 다음 CUDA
호출에서 block된다 → 5/6에서 device 상태를 되돌리기 전까지의 안전한 window. VA를 한 번도
해제하지 않아 데이터버퍼가 같은 주소로 remap되고 복원된 GPU 포인터가 그대로 유효하다.

## 구성

```
runtime/gpu-cr-restore-shim   OCI 런타임 래퍼 (CRI-O 핸들러)
runtime/lib/                  common / stage / gpu-restore 모듈
config/crio/                  핸들러 등록 CRI-O drop-in
config/runtimeclass.yaml      RuntimeClass gpu-cr-restore
deploy/                       샘플 복원 Pod (annotation 기반)
scripts/install-crio-runtime.sh   노드별 설치 스크립트
docs/                         DESIGN.ko / SETUP.ko / SETUP
```

## 빠른 시작

각 GPU 워커: `sudo ./scripts/install-crio-runtime.sh`
클러스터 1회: `kubectl apply -f config/runtimeclass.yaml`
이후 `deploy/sample-restore-pod-l1.yaml`을 채워 apply. 전체 절차는
[docs/SETUP.ko.md](docs/SETUP.ko.md).

## 상태 / 범위

실험용, 단일 컨테이너·단일 GPU 레퍼런스. shim은 투명성·노드 점검 용이성을 위해 crun을
감싼 bash 래퍼이며, 컴파일 런타임은 후속 선택지. 정직한 전제·미검증 지점은
[docs/DESIGN.ko.md](docs/DESIGN.ko.md) 참고.
