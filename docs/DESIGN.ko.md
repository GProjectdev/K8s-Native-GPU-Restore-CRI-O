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
적합하다. GPU 제어상태는 CRIU + cuda_plugin(CRIUgpu)이 복원하고, 데이터는 인터셉터가 remap한다.

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

## 복원 컨테이너로 annotation 전파 (restore-agent 자동화)

> 실측 결과 **crun은 CRIU restore 경로에서 poststart hook을 실행하지 않는다**(정상 `start`에만
> 붙음). 그래서 OCI hook 대신 **host 데몬 `gpu-cr-restore-agent.service`(`restore-agent/`)**
> 가 자동 트리거를 담당한다: crun을 폴링해 `gpu-cr.io/restore=true`(0004로 config.json에 실림)
> + CUDA 상태 `checkpointed`인 컨테이너를 찾아 `gpu-restore.sh`(restore→gate→unlock→remap)를
> 실행한다. k8s API 불필요. OCI hook은 fallback으로 남겨둔다.


CRI-O 복원(`CRImportCheckpoint`)은 컨테이너 annotation을 **체크포인트 이미지에서 다시
만든다**(원본 annotation). 그래서 복원 Pod에 붙인 `gpu-cr.io/*`가 복원 컨테이너의 OCI
spec에 실리지 않아, poststart hook의 `when.annotations: gpu-cr.io/restore=true` 매칭이 실패하고
hook이 `source-pod-uid`도 못 읽는다. `0004-restore-propagate-gpu-cr-annotations.patch`가
복원 Pod의 `gpu-cr.io/*`를 복원 컨테이너 config로 전파해 hook이 자동 발화하게 한다.

## annotation은 "샌드박스"에 담긴다 (중요)

kubelet은 Pod의 임의 annotation(`gpu-cr.io/*`)을 **컨테이너가 아니라 Pod 샌드박스**
(`PodSandboxConfig.Annotations`)로 전달한다. 따라서 패치는 `CreateContainer`에서
`req.GetSandboxConfig().GetAnnotations()`를 읽어야 하며, 컨테이너 config annotation만
읽으면 키가 비어 조용히 no-op가 되어 복원이 안 걸린다(증상: `/var/lib/gpu-cr/restore/`가
비고 `Completed`). 또한 poststart hook이 매칭하도록 `gpu-cr.io/*`를 컨테이너 config
annotation으로 **전파**한다(안 되면 런타임에 `allowed_annotations` 추가 필요).

## 패치 (crio-patch/)

- **`server/gpu_cr_restore.go`** (새 파일): `stageGPUCheckpoint(ctx, sbAnn, cfg)` —
  `gpu-cr.io/restore=true`면 **두 파일**을 노드로 staging (file/hostpath/nfs/https):
  (a) `gpu-cr.io/checkpoint-uri`의 **`.tar`**(CPU+제어상태) → `cfg.Image`를 로컬 경로로 교체,
  (b) 형제 **`.blob`**(GPU 데이터) → `/var/lib/gcr-data/<source-uid>/data.blob`. `.blob` URI는
  기본적으로 `.tar`→`.blob`로 유도하며 `gpu-cr.io/data-uri`로 오버라이드. 아니면 no-op.
- **`0001-create-stage-gpu-checkpoint.patch`**: `CreateContainer` 최상단(체크포인트 감지
  직전)에 `s.stageGPUCheckpoint(...)` 호출 1줄 삽입. cri-o **v1.33.x**에 clean apply 확인.

## GPU 복원 = CRIUgpu(제어상태) + 인터셉터 remap(데이터)

**main 브랜치(CRIUgpu)**: GPU **제어상태**(CUDA 컨텍스트/스트림)는 별도 단계가 아니라
CRIU 복원 중에 NVIDIA **cuda_plugin**이 인라인으로 복원한다. 즉 `crun restore` 하나가
CPU 프로세스 + GPU 제어상태를 함께 되살린다 — 호스트 `cuda-checkpoint` 단계·
`gpu-cr-cuda-helper.service`는 이 경로에서 **필요 없다**. 남는 것은 GCR **데이터** 경로뿐:

1. **(데이터 remap)** — in-Pod 인터셉터에 `GCR_RESTORE(2)` 신호를 control 채널로 전송하면
   인터셉터가 physical을 재생성하고 **동일 VA**에 매핑 후 H2D 복사한다. **CRIU가 원본 env를
   복원**하므로 인터셉터는 원본 `GCR_POD_UID` 경로를 watch → `gpu-cr.io/source-pod-uid`로
   그 키에 신호한다.
2. **누가 신호하나** — crun은 CRIU 복원 경로에서 poststart hook을 실행하지 않으므로, 호스트
   **restore-agent** 데몬이 `gpu-cr.io/restore=true` 컨테이너를 감지해 remap을 구동한다
   (poststart를 지키는 런타임에서는 hook도 동일 동작). 제어상태가 이미 살아있어(cuda-checkpoint
   "checkpointed" 상태가 없음) 감지는 상태값 대신 annotation으로 한다.

> **v1.0 브랜치**는 제어상태를 호스트 `cuda-checkpoint` 헬퍼로 복원하는 방식이다.

## 외부 데이터 blob (GPU 메모리 데이터는 tar 밖에 있다)

체크포인트 인터셉터는 GCR 방식으로 GPU 메모리 데이터를 **CRIU tar에 넣지 않는다.** freeze 때
D2H로 외부 파일 `${GCR_DATA_DIR}/<uid>/data.blob`(기본 `/var/lib/gcr-data`, MAP_SHARED)로
내린 뒤 munmap/close하므로, CRIU는 그 매핑을 external file로만 기록하고 내용은 tar에서 제외한다.
그 결과 저장물은 **`.tar`(CPU + GPU 제어상태) + `.blob`(GPU 데이터)** 두 조각이며, 체크포인트
에이전트가 둘을 같은 basename으로 나란히 저장한다(`...-<ts>.tar`, `...-<ts>.blob`).

복원에서 함의는 분명하다: 인터셉터의 `restore_remap()`은 복원 직후 `data.blob`을 **다시 열어**
H2D로 같은 VA에 복사한다. 따라서 복원 노드에 이 blob이 인터셉터가 여는 경로
(`${GCR_DATA_DIR}/<source-uid>/data.blob`)에 **미리 존재해야** 한다.

- **같은 노드**: 소스 freeze가 이미 그 경로에 blob을 남겨 두었다(그래도 CRI-O가 저장물의 `.blob`을
  다시 스테이징해 authoritative 사본으로 덮는다).
- **다른 노드**: blob이 target에 없다. CRI-O staging이 tar와 함께 `.blob`을 받아
  `/var/lib/gcr-data/<source-uid>/data.blob`에 놓는다. HTTP로 서빙할 때 `.tar`와 `.blob`이 같은
  디렉터리에 있으므로 `.tar`→`.blob` 유도만으로 충분하다.

blob이 없으면 remap이 데이터를 복사하지 못한다(제어상태·프로세스는 살아도 GPU 데이터가 빈다).
그래서 restore-agent는 remap 신호 전에 blob 존재를 확인해 경고를 남긴다.

## GPU 데이터 remap의 race 조율 (RESTORE GATE @ freeze)

문제는 그대로다: **인터셉터의 데이터 remap(같은 VA에 physical 재생성 + H2D)이 끝나기 전에
앱이 커널을 실행하면** 매핑되지 않은 VA를 읽어 `CUDA_ERROR_INVALID_ARGUMENT`로 죽는다.

v1.0에서는 `cuda-checkpoint`의 `locked` 상태가 앱을 잡아 주는 동안 gate를 올리고 unlock했다.
**CRIUgpu에는 그 lock이 없다** — cuda_plugin이 제어상태를 복원하면 프로세스가 곧바로 *running*이
되어 remap 전에 커널을 던질 수 있다. 그래서 gate를 거는 시점을 복원이 아니라 **체크포인트 freeze
시점**으로 옮겼다:

1. 체크포인트 **freeze** 시 인터셉터가 데이터 physical을 해제하기 직전에 gate를 올린다(`g_gate=1`).
2. CRIU 덤프가 이 gate 상태(=1)를 **프로세스 메모리째로 캡처**한다.
3. 복원된 프로세스는 gate=1로 떠오른다 → 첫 커널 런치에서 **자동으로 대기**한다.
4. restore-agent가 `GCR_RESTORE(2)` 신호 → 인터셉터가 remap 후 gate 해제(`g_gate=0`) + `GCR_IDLE(0)`.
5. 대기하던 커널 런치가 unblock → 앱 정상 실행.

즉 앱을 잡아 두는 역할이 외부 lock(cuda-checkpoint)에서 **인터셉터 스스로 캡처된 gate**로 바뀌었다.
덤으로 **소스 측**도 안전해진다: freeze~remap 사이에 소스 앱이 이미 해제된 데이터를 만지지 못한다.
`hooks/lib/gpu-restore.sh`(및 restore-agent)는 이제 remap 신호를 보내고 `GCR_IDLE`만 기다리면 된다.

> 인터셉터 gate-at-freeze는 체크포인트 저장소(interceptor)의 변경이며, CRIUgpu 복원을
> race-free로 만들기 위한 짝 변경이다.

## 왜 이 순서가 안전한가

gate가 **freeze 시점에 캡처**되므로, CRIU 복원 직후 프로세스는 제어상태가 살아 있어 바로
running이지만 **첫 GPU 커널 런치에서 gate에 걸려 대기**한다. 이 window에서 데이터 remap을
끝내면 앱이 유효한 device 포인터로 unblock된다. **VA는 한 번도 해제되지 않았으므로** 같은
주소 remap이 성립한다.

## 전체 흐름 (8단계)

| 단계 | 주체 | 동작 |
|---|---|---|
| 1 | 사용자 | Restore Pod yaml apply (image = 체크포인트 아카이브 경로) |
| 2 | 스케줄러 | target 노드 선택 (실험: `nodeSelector`) |
| **2.5** | **Custom CRI-O (patch)** | `.tar`(→image 경로 치환) + 형제 `.blob`(→`/var/lib/gcr-data/<uid>/data.blob`) staging |
| 2.6 | device plugin | `nvidia.com/gpu` 할당 / `/dev/nvidia*` |
| 3 | kubelet → CRI-O | 로컬 아카이브 감지 → 네이티브 복원 분기 |
| 4 | CRI-O/CRIU + cuda_plugin | 컨테이너 + CPU 프로세스 + **GPU 제어상태** 복원 (CRIUgpu) |
| 5 | restore-agent | 복원된 컨테이너(`gpu-cr.io/restore=true`) 감지 |
| 6 | restore-agent → interceptor | `.blob` 재오픈 → GPU 데이터버퍼 remap (동일 VA + H2D) |
| 7 | 복원된 프로세스 | gate에 대기하던 커널 런치 unblock → workload resume |
| 8 | CRI-O/kubelet | 정상 Running 컨테이너로 등록 |

## kubelet 이미지 이름 제약 (중요)

kubelet은 CRI-O 호출 **이전에** Pod의 `image`를 OCI 레퍼런스 형식으로 검증한다. 따라서
`image`에 파일 경로(`/var/lib/.../Checkpoint.tar`)를 넣으면 CRI-O에 닿기 전에
`InvalidImageName`으로 거부된다. 그래서 복원 Pod는:

- `image`: **유효하고 노드에 이미 있는 레퍼런스**(placeholder, 예: 원본 이미지) +
  `imagePullPolicy: IfNotPresent`
- 실제 복원 대상: `gpu-cr.io/checkpoint-uri` annotation

으로 지정한다. 패치의 `stageGPUCheckpoint`가 CreateContainer 안에서 `image`를 스테이징된
로컬 아카이브로 **내부 교체**하므로 kubelet은 이 교체를 보지 못한다. (crictl/podman 직접
복원은 파일 경로 image가 허용되지만, kubelet 경유는 이 방식이 필요.)

## NVIDIA bind mount 요구 (복원 관문)

원본 GPU 컨테이너는 nvidia-container-runtime이 드라이버 라이브러리/바이너리(수십 개)를
bind mount로 주입한 상태로 체크포인트된다. CRI-O 복원 검증(`server/container_restore.go`)은
체크포인트가 기록한 각 mount의 destination이 **새 Pod의 CRI mount 목록에 존재**하기를
요구한다(없으면 `expects following bind mounts defined (...)`). nvidia 주입은 CRI-O 검증
*이후*에 일어나므로, 복원 Pod는 그 경로들을 **명시적 hostPath volumeMount**로 제공해야 한다.

`scripts/gen-nvidia-restore-mounts.sh`가 그 에러 목록을 volumeMounts+volumes YAML로
변환해 준다(드라이버 버전에 종속적이므로 버전 바뀌면 재생성). 예: `deploy/sample-restore-pod-l1-nvidia.yaml`.

또한 일부 NVIDIA 설정 파일(vulkan/EGL/X11 json 등)은 **host source 경로가 destination과
달라서**(또는 nvidia-container-toolkit이 다른 위치에서 mount) 같은-경로 hostPath로는
런타임에 "bind mount source ... is missing"으로 실패한다. `scripts/gen-restore-pod.sh`는
**체크포인트 tar의 `spec.dump`에서 각 mount의 실제 source→destination을 읽어** 정확한
매니페스트를 생성한다(host에 없는 source는 경고 후 제외). 이쪽이 권장 경로다.

## 가능성 판단 / 미검증 지점 (정직하게)

1. **컴파일 미검증**: 이 환경엔 Go 툴체인이 없어 `gpu_cr_restore.go`와 patch는 **빌드/실측
   미검증**이다. `hack/build-crio.sh`로 노드와 동일한 cri-o(예: v1.33.13)에 적용해 빌드해야 한다. patch의 clean
   apply만 확인됨.
2. **CRI-O 버전**: patch는 **v1.33.x 기준**(빌드 기본값 v1.33.13). container_restore.go가 `createConfig.Linux`를 쓰는 1.33 계열에 맞음 — v1.35처럼 `GetLinux()`인 버전이면 0004 앵커를 rebase해야 한다.
3. **source-pod-uid 의존**: 데이터 remap이 원본 UID 키에 의존. 체크포인트 tar에 원본 UID를
   메타로 저장하면 annotation 없이 자동화 가능(후속).
4. **이미지/rootfs 호환성**, **device plugin 선행**: CRIU 복원 시점에 GPU 디바이스 접근이
   준비돼 있어야 함.
5. **단일 컨테이너/단일 GPU** 기준. 멀티프로세스(NCCL)·멀티GPU는 후속.
6. **TCP 소켓 제약 (실측)**: CRI-O→conmon→`crun restore` 경로는 복원 시 CRIU에 `tcp-close`를
   전달하지 못한다(`default.conf`는 RPC에 덮이고, `crun.conf`/`org.criu.config`도 이 경로에선
   CRIU로 포워딩 안 됨). 따라서 **체크포인트 시점에 established TCP가 있으면**
   `image.c:94: Need to set the --tcp-close options`로 복원이 실패한다. 현재 확실한 해법은
   워크로드를 오프라인으로 만들고 소스 `default.conf`에서 tcp-close를 빼 **소켓 없는 깨끗한
   체크포인트**를 뜨는 것(§SETUP.ko.md 7). `install-node.sh`의 `/etc/criu/crun.conf` +
   0004의 `org.criu.config` 주입은 crun이 포워딩을 지원하는 환경을 위한 대비책이다.

## 검증 전략

`deploy/sample-restore-pod-l1.yaml`로 체크섬 워크로드를 복원해, 복원 후 GPU 텐서 체크섬이
체크포인트 시점과 **동일**한지로 end-to-end 정합성을 확인한다.
