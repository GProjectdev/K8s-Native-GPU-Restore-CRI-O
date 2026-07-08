# 실험 가이드 — GPU Restore (Custom CRI-O)

`Checkpoint.tar`를 새 Pod로 복원하는 절차. 대상: K8s v1.33+, **CRI-O v1.35.0**(패치 빌드),
NVIDIA 드라이버 570+.

## 0. 전제
- 체크포인트 시스템 설치 + `Checkpoint.tar` 생성 완료.
- 각 GPU 워커: 드라이버 570+, **CRIUgpu**(CRIU + NVIDIA `cuda_plugin` **활성화**),
  인터셉터 lib(`/var/lib/gpu-cr/lib/libgcr-interceptor.so`), NVIDIA device plugin,
  patch crio + `scripts/install-node.sh`(restore-agent 포함).
  - cuda_plugin이 GPU 제어상태를 CRIU 복원 중에 복원하므로 호스트 `cuda-checkpoint` 헬퍼는
    이 경로에서 불필요하다(체크포인트 저장소의 `gpu-worker-setup.sh`가 cuda_plugin을 켠다).
- **노드 간 복원 시: source·target 노드의 NVIDIA 드라이버 버전이 동일해야 함**
  (예: 570.211.01). CRIUgpu(cuda_plugin) 복원의 근본 제약이자 드라이버 라이브러리 경로 일치 조건.

## 1. Custom CRI-O 빌드 (빌드 호스트, 1회)
```bash
git clone https://github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O.git
cd K8s-Native-GPU-Restore-CRI-O
./hack/build-crio.sh          # cri-o v1.35.0 clone + 패치 + 빌드
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
기대: crio 로그에 `gpu-cr: staged checkpoint`, 네이티브 CRIU 복원(cuda_plugin이 제어상태
복원), restore-agent 로그에 `remapping GPU data ...` / `container ... restored`,
워크로드 체크섬 `OK`.

## 6. 트러블슈팅
| 증상 | 조치 |
|---|---|
| 일반 이미지로 pull 시도 | image가 staging 후 로컬 파일로 바뀌는지(crio 로그 `gpu-cr: staged`), `enable_criu_support` 확인 |
| `stage checkpoint ... no such file` | `checkpoint-uri` 경로/스킴 확인, target 노드 staging |
| hook 미동작 | `hooks_dir`에 oci-hooks 등록됐는지, `gpu-cr.io/restore=true` annotation, hook 실행권한 |
| 복원 직후 `CUDA_ERROR_INVALID_ARGUMENT`/크래시 | 인터셉터 gate-at-freeze(체크포인트 저장소) 적용 여부, cuda_plugin 활성화 확인 |
| remap ack 없음 | restore-agent 실행 여부, `source-pod-uid` 일치, control 디렉터리 마운트 |

## 대안: 포크 없는 shim
CRI-O를 빌드하기 어렵다면 `alt-shim/`의 런타임 핸들러 방식을 쓸 수 있다(견고성은 낮음).
`alt-shim/install-crio-runtime.sh` 참고.
