# 실험 가이드 — GPU Restore (Custom CRI-O)

`Checkpoint.tar`를 새 Pod로 복원하는 절차. 대상: K8s v1.33+, **CRI-O v1.33.x**(노드 버전에 맞춰 패치 빌드),
NVIDIA 드라이버 570+, **crun ≥ 1.9**.

## 0. 전제
- 체크포인트 시스템 설치 + `Checkpoint.tar` 생성 완료.
- 각 GPU 워커: 드라이버 570+, **CRIUgpu**(CRIU + NVIDIA `cuda_plugin` **활성화**),
  인터셉터 lib(`/var/lib/gpu-cr/lib/libgcr-interceptor.so`), NVIDIA device plugin,
  patch crio + `scripts/install-node.sh`(restore-agent 포함),
  **`/var/lib/gcr-data` hostPath**(인터셉터가 GPU 데이터 `data.blob`을 읽고 쓰는 위치).
  - cuda_plugin이 GPU 제어상태를 CRIU 복원 중에 복원하므로 호스트 `cuda-checkpoint` 헬퍼는
    이 경로에서 불필요하다(체크포인트 저장소의 `gpu-worker-setup.sh`가 cuda_plugin을 켠다).
- **노드 간 복원 시: source·target 노드의 NVIDIA 드라이버 버전이 동일해야 함**
  (예: 570.211.01). CRIUgpu(cuda_plugin) 복원의 근본 제약이자 드라이버 라이브러리 경로 일치 조건.

## 1. Custom CRI-O 빌드 (빌드 호스트, 1회)
```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O
CRIO_VERSION=v1.33.13 ./hack/build-crio.sh   # 노드 버전에 맞춰(crio --version) clone + 패치 + 빌드
```
산출물: `/tmp/cri-o-gpu-cr/bin/crio`.

## 2. 노드 설치 (각 GPU 워커)
```bash
# (a) 패치된 crio 바이너리 교체
sudo install -m0755 /tmp/cri-o-gpu-cr/bin/crio "$(command -v crio)"
# (b) hook + CRI-O drop-in + 디렉터리
sudo ./scripts/install-node.sh
sudo systemctl restart crio
```
확인:
```bash
crio config | grep -E 'enable_criu_support|hooks_dir'
ls /usr/local/lib/gpu-cr-restore/oci-hooks/gpu-cr-restore.json
```

## 3. 체크포인트 준비
같은 노드면 tar가 이미 `/var/lib/gcr-checkpoint`에 있다. **다른 노드로 복원(마이그레이션)이면
`checkpoint-uri`를 `http(s)://`/`nfs://`로 지정** — 자세한 절차는 [MIGRATION.ko.md](MIGRATION.ko.md).
원본 Pod UID:
```bash
kubectl get pod <원본-pod> -o jsonpath='{.metadata.uid}'
```

## 4. 복원 Pod apply
`deploy/sample-restore-pod-l1.yaml`에서 `REPLACE_WITH_SOURCE_POD_UID`,
`checkpoint-uri`, `image`(스테이징될 로컬 경로), `nodeSelector`를 채운 뒤:
```bash
kubectl apply -f deploy/sample-restore-pod-l1.yaml
kubectl get pod restore-cuda-l1 -w
```

## 5. 검증
```bash
kubectl get pod restore-cuda-l1 -o wide
sudo journalctl -u crio | grep -E 'gpu-cr|Assuming it is a checkpoint' | tail -40
kubectl logs restore-cuda-l1 | tail -5     # checksum ... OK
```
기대: crio 로그에 `gpu-cr: staged checkpoint` + `gpu-cr: staged GPU data blob ... -> /var/lib/gcr-data/<uid>/data.blob`,
네이티브 CRIU 복원(cuda_plugin이 제어상태 복원), restore-agent 로그에 `remapping GPU data ...` /
`container ... restored`, 워크로드 체크섬 `OK`.

## 6. 트러블슈팅
| 증상 | 조치 |
|---|---|
| 일반 이미지로 pull 시도 | image가 staging 후 로컬 파일로 바뀌는지(crio 로그 `gpu-cr: staged`), `enable_criu_support` 확인 |
| `stage checkpoint ... no such file` | `checkpoint-uri` 경로/스킴 확인, target 노드 staging |
| hook 미동작 | `hooks_dir`에 oci-hooks 등록됐는지, `gpu-cr.io/restore=true` annotation, hook 실행권한 |
| 복원 직후 `CUDA_ERROR_INVALID_ARGUMENT`/크래시 | 인터셉터 gate-at-freeze(체크포인트 저장소) 적용 여부, cuda_plugin 활성화 확인 |
| CRIU restore `-52` + `Need to set the --tcp-close options` | **체크포인트에 소켓 흔적이 남은 것.** 아래 §7 참고 — 소스에서 소켓 없는 깨끗한 체크포인트를 떠야 한다. |
| remap ack 없음 | restore-agent 실행 여부, `source-pod-uid` 일치, control 디렉터리 마운트 |

## 7. TCP 소켓 / 네트워크 워크로드 주의 (중요, 실측)

CRIU는 established TCP 소켓을 특별 처리한다(덤프 시 `--tcp-close` 또는 `--tcp-established`
필요). 문제는 **CRI-O→conmon→`crun restore` 경로가 복원 시 CRIU에 `tcp-close`를 전달하지
못한다**는 것. `/etc/criu/default.conf`는 복원 RPC에 덮이고, `/etc/criu/crun.conf`·
`org.criu.config`도 이 경로에선 CRIU로 포워딩되지 않았다(로그에 crun.conf 파싱 흔적 없음).
그 결과, **소켓 흔적이 있는 체크포인트**를 복원하면 다음에서 즉사한다:

```
Error (criu/image.c:94): Need to set the --tcp-close options.   # CRIU restore -52
```

이건 GPU 이전에, 프로세스 메모리 복원 전 초기 메타데이터 게이트다(blob/cuda_plugin과 무관).

**해결 — "소켓 없는 깨끗한 체크포인트"를 떠라:**

1. **워크로드가 실행 중 네트워크를 안 쓰게** 한다. 예: HF 모델은 로컬 경로에서 오프라인 로드.
   ```yaml
   env:
     - { name: MODEL, value: "/models/opt-1.3b" }   # repo id 아님, 마운트된 로컬 경로
     - { name: HF_HUB_OFFLINE, value: "1" }
     - { name: TRANSFORMERS_OFFLINE, value: "1" }
   # 모델 폴더를 hostPath/NFS로 /models 에 마운트. 복원 노드에도 같은 경로로 마운트.
   ```
2. **소스 노드 `/etc/criu/default.conf`에서 `tcp-close`를 제거**한다(있으면 덤프가 이미지에
   그 요구를 박는다).
   ```bash
   sudo sed -i '/^tcp-close$/d' /etc/criu/default.conf
   ```
3. 체크포인트 직전 **열린 TCP가 0인지 확인**(호스트에서 그 컨테이너 PID의 netns 검사):
   ```bash
   pid=$(for p in $(pgrep -x python); do grep -qa '<MODEL 표식>' /proc/$p/environ && echo $p; done | head -1)
   sudo cat /proc/$pid/net/tcp /proc/$pid/net/tcp6 | awk '$1 ~ /^[0-9]+:/ && $4!="0A"'   # 빈 결과 = TCP 없음
   ```
4. 그 상태로 **재체크포인트** → 새 이미지엔 tcp 요구가 없어 복원이 그대로 통과한다.

> 참고: `install-node.sh`는 `/etc/criu/crun.conf`(tcp-close, ext-unix-sk)를 만들고, 복원 패치는
> `org.criu.config`로 crun에 넘기려 시도한다. 하지만 위처럼 이 CRI-O/crun 조합에선 포워딩이
> 확인되지 않았으므로, **현재 확실한 방법은 소켓 없는 체크포인트**다. (crun/conmon이 이후
> 버전에서 포워딩을 지원하면 config 경로도 유효해진다.)

## 대안: 포크 없는 shim
CRI-O를 빌드하기 어렵다면 `alt-shim/`의 런타임 핸들러 방식을 쓸 수 있다(견고성은 낮음).
`alt-shim/install-crio-runtime.sh` 참고.
