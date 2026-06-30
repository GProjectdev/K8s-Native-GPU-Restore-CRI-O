# 실험 가이드 — GPU Restore (CRI-O)

체크포인트 시스템으로 만든 `Checkpoint.tar`를 새 Pod로 복원하는 실험 절차.
검증 환경: K8s v1.33 + CRI-O v1.33, NVIDIA 드라이버 570+, crun.

## 0. 전제

- 체크포인트 시스템(`K8s-Native-Fast-GPU-Checkpoint-Restore-System`)이 설치돼 있고
  `Checkpoint.tar`가 만들어져 있다(`docs/SETUP.ko.md`).
- 각 GPU 워커에 다음이 준비됨:
  - 드라이버 570+, `cuda-checkpoint`, CRIU, crun, CRI-O(`enable_criu_support`)
  - `gpu-cr-cuda-helper.service` (host helper) 가 `restore <pid>` 요청을 처리하도록 동작
  - 인터셉터 라이브러리(`/var/lib/gpu-cr/lib/libgcr-interceptor.so`)
  - device plugin (`nvidia.com/gpu` 할당)

## 1. 런타임 핸들러 설치 (각 GPU 워커)

```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O
sudo ./scripts/install-crio-runtime.sh
```

스크립트가 하는 일: shim+lib를 `/usr/local/lib/gpu-cr-restore`에 설치,
`/usr/local/bin/gpu-cr-restore-shim` 심링크, CRI-O drop-in
(`/etc/crio/crio.conf.d/99-gpu-cr-restore.conf`) 배치, `crio` 재시작.

확인:

```bash
crio config | grep -A4 'gpu-cr-restore'
sudo /usr/local/bin/gpu-cr-restore-shim --help >/dev/null 2>&1; echo "shim ok"
```

## 2. RuntimeClass 등록 (클러스터 1회)

```bash
kubectl apply -f config/runtimeclass.yaml
kubectl get runtimeclass gpu-cr-restore
```

## 3. 복원할 체크포인트 준비

같은 노드 복원이면 체크포인트 tar가 이미 `/var/lib/gcr-checkpoint`에 있다.
다른 노드로 migration이면 target 노드로 tar를 옮긴다(또는 `nfs://`/`https://` URI 사용).

원본 Pod UID 확인(데이터 remap 신호 키):

```bash
kubectl get pod <원본-pod> -o jsonpath='{.metadata.uid}'
```

## 4. 복원 Pod apply

`deploy/sample-restore-pod-l1.yaml`에서 `REPLACE_WITH_SOURCE_POD_UID`,
`checkpoint-uri`, `nodeSelector hostname`을 채운 뒤:

```bash
kubectl apply -f deploy/sample-restore-pod-l1.yaml
kubectl get pod restore-cuda-l1 -w
```

## 5. 검증

```bash
# (a) 컨테이너가 Running 으로 등록됐는가
kubectl get pod restore-cuda-l1 -o wide

# (b) shim 로그 — staging / CRIU restore / GPU restore 단계
sudo journalctl -u crio | grep gpu-cr-restore | tail -40

# (c) 데이터 정합성 — 복원된 워크로드 체크섬이 체크포인트 시점과 동일한가
kubectl logs restore-cuda-l1 | tail -5     # checksum=... OK
```

기대: shim 로그에 `staged checkpoint`, `CRIU restore done`,
`host helper restore ok`, `interceptor remap ack` 가 차례로 찍히고,
워크로드 체크섬이 `OK`.

## 6. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| Pod가 ContainerCreating에서 멈춤 | `journalctl -u crio` 확인. shim이 crun restore 단계에서 실패했는지 |
| `checkpoint not found on node` | tar가 target 노드에 없음 → staging(3) 다시. `hostpath://` 경로 확인 |
| `host helper timeout` | `gpu-cr-cuda-helper.service`가 `restore` 명령을 처리하는지 확인 |
| `interceptor remap` ack 없음 | `source-pod-uid`가 원본과 일치하는지, control 디렉터리 마운트 확인 |
| CRIU `Can't dump/restore` 류 | 드라이버 570+ 인지, 이미지가 체크포인트와 호환되는지 |
