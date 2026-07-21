# 노드 간 마이그레이션 (Cross-node Restore)

한 노드(source)에서 뜬 `Checkpoint.tar`를 **다른 노드(target)로 복원**하는 절차.
검증 완료: worker-1에서 체크포인트 → worker-2로 복원, GPU 워크로드가 재개되고 체크섬 일치.

## 전제 (중요)

- **source·target 노드의 NVIDIA 드라이버 버전이 동일**해야 한다(예: `570.211.01`).
  - CRIUgpu(cuda_plugin) 제어상태 복원은 드라이버 버전이 맞아야 동작하고,
  - 드라이버 라이브러리 경로(`…so.570.211.01`)가 target에 존재해야 마운트가 붙는다.
  - 확인: `ssh <target> nvidia-smi | grep Driver`
- target 노드에 이 시스템 설치 완료: patch crio + `scripts/install-node.sh`
  (hook + **restore-agent**) + **CRIUgpu(cuda_plugin 활성화)** + 인터셉터 lib + device plugin.
- target 노드에 **`/var/lib/gcr-data` hostPath 존재**(복원 Pod가 이 경로를 마운트하고 인터셉터가
  `data.blob`을 읽는다). CRI-O staging이 여기에 blob을 놓는다.
- source·target이 같은 네트워크(VPC 내부)에서 통신 가능.
- 모든 노드 **crun ≥ 1.9**.
- **소켓 없는 깨끗한 체크포인트**여야 한다 — 워크로드가 체크포인트 시점에 TCP 소켓을 물고
  있으면 복원이 `CRIU -52 / --tcp-close`로 실패한다(CRI-O/crun이 복원 시 tcp-close 미전달).
  워크로드를 오프라인으로 만들고 소스 `/etc/criu/default.conf`에서 tcp-close 제거. 상세: SETUP.ko.md §7.
- 모델을 파일로 로드한다면 source·target에 **동일 경로로 마운트**되어 있어야 한다(mmap 복원).

## 절차

### 1) source 노드에서 체크포인트 tar를 HTTP로 서빙

가장 간단한 방법. source 노드(예: 10.178.0.11)에서 tar 디렉터리를 잠깐 노출한다.

```bash
cd /var/lib/gcr-checkpoint
python3 -m http.server 8000 --bind 10.178.0.11
```

> 서버 루트가 그 폴더이므로 URL 경로는 **파일명만** 붙인다. (루트 `/`에서 서빙했다면
> `.../8000/var/lib/gcr-checkpoint/<file>` — 슬래시 하나. `///` 같은 중복 슬래시는 오류.)

이 폴더에는 체크포인트당 **두 파일**(`...-<ts>.tar`, `...-<ts>.blob`)이 함께 있다. 같은 HTTP
서버에서 둘 다 노출되므로, CRI-O가 `.tar`→`.blob`로 유도해 blob도 자동으로 내려받는다.

target 노드에서 연결 확인 (두 파일 모두 200):

```bash
curl -sI "http://10.178.0.11:8000/checkpoint-<...>.tar"    # HTTP 200 + Content-Length
curl -sI "http://10.178.0.11:8000/checkpoint-<...>.blob"   # HTTP 200 (GPU 데이터, 필수)
```

`nfs://<server>/<export>/<file>.tar` 또는 미리 `scp` 후 `hostpath://` 도 지원한다(이 경우
`.blob`도 같은 위치에 함께 두면 된다). blob이 다른 곳에 있으면 `gpu-cr.io/data-uri`로 지정한다.

### 2) 복원 매니페스트 생성 (target 노드 지정, 원격 URI)

tar가 있는(그리고 드라이버가 깔린) 노드에서 실행 — NVIDIA 마운트는 tar의 `spec.dump`에서
자동 추출된다.

```bash
./scripts/gen-restore-pod.sh /var/lib/gcr-checkpoint/checkpoint-<...>.tar \
  --name restore-cuda-l1 \
  --uid <원본 Pod UID> \
  --node jsj-worker-2 \
  --uri "http://10.178.0.11:8000/checkpoint-<...>.tar" \
  > /tmp/restore-xnode.yaml
```

바뀌는 것은 딱 두 가지다:
- `gpu-cr.io/checkpoint-uri` → 원격 `http(s)://`(또는 `nfs://`)
- `nodeSelector` → target 노드

그대로 두는 것: `gpu-cr.io/source-pod-uid`, `image`, **NVIDIA 마운트 블록**
(드라이버 버전이 같으면 모든 노드에서 동일한 경로).

### 3) 적용 (이후 자동)

```bash
kubectl apply -f /tmp/restore-xnode.yaml
kubectl get pod restore-cuda-l1 -o wide       # NODE=jsj-worker-2, Running
kubectl logs restore-cuda-l1 --tail=12        # remap: … restored + checksum … OK
```

target 노드의 Custom CRI-O가 tar를 내려받아(staging) 네이티브 CRIU 복원 →
제어상태는 CRIU + cuda_plugin이 복원 중 되살리고(CRIUgpu), CRI-O가 `.blob`을
`/var/lib/gcr-data/<uid>/data.blob`에 스테이징하며, restore-agent가 자동으로 인터셉터 데이터
remap(blob 재오픈 → H2D)을 수행한다. 수동 명령 없이 완료된다.

## 검증 로그 (참고)

target 노드 crio 로그에 다음이 순서대로 보이면 정상:

```
gpu-cr: restore annotation detected for container "cuda-app"
gpu-cr: staged checkpoint "http://<source>:8000/…tar" -> /var/lib/gpu-cr/restore/…; restoring from local archive
```
그리고 Pod 로그에:
```
[gcr][engine] remap: 2 segs restored to same VA + H2D; 0 failed
checksum=… OK
```
`nvidia-smi`(target)에 복원 프로세스가 GPU 메모리(~데이터 크기)를 점유하면 완료.
