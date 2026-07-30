# 사용 가이드 — GPU Restore (Custom CRI-O)

이 시스템은 stock CRI-O에 **staging 패치 + GPU 복원 hook**을 더한 "Custom CRI-O"다.
아래는 (A) 깨끗한 신규 설치, (B) **기존에 CRI-O가 이미 설치/운영 중인 노드에 적용**하는
두 경로를 다룬다. 대부분의 실험은 (B)다.

---

## 0. 가장 먼저: CRI-O 버전 맞추기 (필수)

패치는 **노드가 실제로 돌리는 CRI-O 버전과 동일한 소스로 빌드**해야 한다. 버전이 다른
바이너리로 교체하면 kubelet↔CRI-O 호환이 깨진다.

```bash
crio --version          # 예: crio version 1.33.4  -> CRIO_VERSION=v1.33.4
kubelet --version       # K8s 마이너와 CRI-O 마이너는 보통 일치(1.33 <-> 1.33)
```

체크포인트 시스템은 **K8s v1.33 + CRI-O v1.33**에서 검증됐으므로, 그 노드라면
`CRIO_VERSION=v1.33.x`로 빌드한다(패치 기본값은 v1.33.13이며, 노드 버전에 정확히 맞춰라).

---

## A. 신규 설치 (CRI-O 미설치 노드)

CRI-O 설치 자체는 배포판 가이드를 따르고, 그 버전에 맞춰 본 패치를 빌드해 바이너리만
교체하면 된다. 사실상 아래 B의 빌드+설치 절차와 동일하다.

---

## B. 기존 CRI-O가 설치된 노드에 적용 (권장 경로)

### B-1. 패치된 CRI-O 빌드 (빌드 호스트 1회)

> **빌드 전제조건 (필수).** 빌드 호스트에 아래가 없으면 `go: command not found` 또는
> `make Error 127`로 실패한다. cri-o 1.33은 **Go >= 1.24.3**로 빌드해야 한다.
>
> ```bash
> # Go 1.24.x 설치 (없거나 구버전일 때)
> GO_VER=go1.24.6
> curl -sSfL "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" | sudo tar -xz -C /usr/local
> export PATH=$PATH:/usr/local/go/bin      # 영구 적용은 ~/.bashrc 에 추가
> go version                                # go version go1.24.6 ...
>
> # 빌드 의존 (Debian/Ubuntu)
> sudo apt-get update && sudo apt-get install -y make gcc pkg-config \
>   libseccomp-dev libgpgme-dev libbtrfs-dev libassuan-dev
> ```
> `build-crio.sh`는 시작 시 go/도구 유무와 go 버전(go.mod 대비)을 먼저 점검하고,
> 부족하면 위 안내를 출력하며 멈춘다.

```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O

# 노드의 CRI-O 버전으로 빌드 (예: 1.33.4)
CRIO_VERSION=v1.33.4 ./hack/build-crio.sh
# 산출물: /tmp/cri-o-gpu-cr/bin/crio
```

패치가 그 버전에 적용 안 되면 스크립트가 멈추고 수동 삽입 위치를 안내한다(아래 "버전 rebase").
빌드 호스트엔 go(>=1.22), make, git, cri-o 빌드 의존(libgpgme/libseccomp/libbtrfs dev)이 필요.

### B-2. 기존 바이너리 백업 + 교체 (각 노드)

```bash
CRIO_BIN="$(command -v crio)"            # 보통 /usr/bin/crio 또는 /usr/local/bin/crio
sudo cp -a "$CRIO_BIN" "${CRIO_BIN}.orig.$(date +%Y%m%d)"   # 백업(롤백용)

sudo systemctl stop crio
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$CRIO_BIN"
```

### B-3. hook + 설정 설치 (각 노드)

```bash
sudo ./scripts/install-node.sh     # OCI hook + drop-in + 디렉터리 생성 + crio 재시작
```

`install-node.sh`가 넣는 것:
- `/usr/local/lib/gpu-cr-restore/{hooks,oci-hooks}` — poststart hook + 셸 lib
- `/etc/crio/crio.conf.d/99-gpu-cr-restore.conf` — `enable_criu_support=true`, `hooks_dir`에
  본 hook 디렉터리 **추가**(기존 `/etc/containers/oci/hooks.d` 등은 유지)
- `/var/lib/gpu-cr/{restore,run,cuda-req}`, `/var/lib/gcr-checkpoint`

> 이미 `crio.conf`에 `hooks_dir`를 커스텀으로 쓰고 있다면, drop-in의 배열이 기존 값을
> **덮어쓴다**(CRI-O는 동일 키의 마지막 drop-in을 적용). 기존 hooks_dir 항목을
> `99-gpu-cr-restore.conf`에 합쳐 넣을 것.

### B-4. 기존 설정과의 충돌 점검

```bash
crio config | grep -E 'enable_criu_support|hooks_dir|default_runtime'
sudo crio status info 2>/dev/null | head     # 살아있는지
sudo journalctl -u crio -n 50 --no-pager      # 재시작 에러 없는지
kubectl get nodes                              # 노드가 Ready 유지되는지
```

`enable_criu_support`는 체크포인트 시스템에서도 켜야 하므로 보통 이미 true다.

### B-5. RuntimeClass는 필요 없음

이 방식은 CRI-O 네이티브 복원 경로를 쓰므로 **별도 RuntimeClass/runtimeClassName이
필요 없다.** Pod는 annotation만으로 동작한다(아래). (shim 대안인 `alt-shim/`만
RuntimeClass를 쓴다.)

---

## C. 복원 실행

```bash
# 1) 원본(체크포인트된) Pod UID 확보 — 데이터 remap 신호 키
kubectl get pod <원본-pod> -o jsonpath='{.metadata.uid}'

# 2) deploy/sample-restore-pod-l1.yaml 채우기:
#    - gpu-cr.io/source-pod-uid: 위 UID
#    - gpu-cr.io/checkpoint-uri: tar 위치 (같은노드 hostpath:// / 타노드 nfs:// https://)
#    - image: staging될 노드 로컬 경로 (예: /var/lib/gpu-cr/restore/cuda-app-Checkpoint.tar)
#    - nodeSelector: 대상 노드 hostname

kubectl apply -f deploy/sample-restore-pod-l1.yaml
kubectl get pod restore-cuda-l1 -w
```

검증:

```bash
sudo journalctl -u crio | grep -E 'gpu-cr|checkpoint archive' | tail
# 기대: "gpu-cr: staged checkpoint ..." -> 네이티브 복원(cuda_plugin이 제어상태 복원) ->
#       restore-agent: "remapping GPU data ...", "container ... restored"
kubectl logs restore-cuda-l1 | tail -5         # checksum ... OK
```

---

## D. 롤백 (원래 CRI-O로 복귀)

```bash
sudo systemctl stop crio
sudo install -m0755 "${CRIO_BIN}.orig.YYYYMMDD" "$CRIO_BIN"
sudo rm -f /etc/crio/crio.conf.d/99-gpu-cr-restore.conf
sudo systemctl restart crio
```

hook 디렉터리(`/usr/local/lib/gpu-cr-restore`)는 남겨도 무방(매칭 annotation 없으면 미동작).

---

## E. 버전 rebase (패치가 그 CRI-O 버전에 안 붙을 때)

`server/container_create.go`의 `CreateContainer`에서 "Creating container" 로그 직후,
체크포인트 아카이브 감지 **이전**에 한 줄을 넣는다:

```go
if err := s.stageGPUCheckpoint(ctx, req.GetConfig()); err != nil {
    return nil, fmt.Errorf("gpu-cr staging: %w", err)
}
```

`server/gpu_cr_restore.go`(이 repo의 `crio-patch/server/`)를 그대로 복사해 넣으면 된다.
import에 `fmt`가 없으면 추가.

---

## F. 영문 요약
See `docs/USAGE.md`.
