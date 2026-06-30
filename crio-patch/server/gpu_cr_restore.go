package server

// gpu_cr_restore.go — GPU checkpoint/restore integration for CRI-O.
//
// This is the minimal customization that turns stock CRI-O into the "Custom
// CRI-O" used by the K8s-Native GPU checkpoint/restore system. It adds ONE
// thing to the native restore path: staging.
//
// CRI-O already restores a container from a checkpoint when the container image
// resolves to a local checkpoint archive (see CreateContainer ->
// "Assuming it is a checkpoint archive" -> CRImportCheckpoint). That requires
// the Checkpoint.tar to already exist on THIS node. For a restore on a node
// other than where the checkpoint was taken (migration), the tar must first be
// brought here. stageGPUCheckpoint does exactly that, driven by Pod annotations:
//
//	gpu-cr.io/restore: "true"
//	gpu-cr.io/checkpoint-uri: "<scheme>://<location>/<path>"
//
// It fetches the referenced archive onto the node and rewrites the container's
// image to the local staged path, so CRI-O's existing checkpoint detection and
// CRIU restore pick it up unchanged. The GPU-specific control-state and
// data-buffer restore run afterwards as an OCI poststart hook (see
// oci-hooks/gpu-cr-restore.json), so this file does not touch the device.
//
// Wiring: call s.stageGPUCheckpoint(ctx, req.GetConfig()) at the top of
// CreateContainer, before the "checkpoint archive" detection (see the patch in
// crio-patch/0001-create-stage-gpu-checkpoint.patch).

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	types "k8s.io/cri-api/pkg/apis/runtime/v1"

	"github.com/cri-o/cri-o/internal/log"
)

const (
	gpuCRRestoreAnnotation = "gpu-cr.io/restore"
	gpuCRURIAnnotation     = "gpu-cr.io/checkpoint-uri"
	gpuCRStageDir          = "/var/lib/gpu-cr/restore"
)

// stageGPUCheckpoint makes the checkpoint referenced by gpu-cr.io/checkpoint-uri
// available on this node and points the container image at the local archive.
// It is a no-op unless the container carries gpu-cr.io/restore=true. When the
// annotation is set but no URI is given, the existing image is assumed to be a
// valid local archive or checkpoint OCI image and is left untouched.
func (s *Server) stageGPUCheckpoint(ctx context.Context, cfg *types.ContainerConfig) error {
	if cfg == nil {
		return nil
	}

	ann := cfg.GetAnnotations()
	if ann[gpuCRRestoreAnnotation] != "true" {
		return nil
	}

	uri := strings.TrimSpace(ann[gpuCRURIAnnotation])
	if uri == "" {
		log.Infof(ctx, "gpu-cr: restore requested without %s; using image %q as-is",
			gpuCRURIAnnotation, cfg.GetImage().GetImage())
		return nil
	}

	name := cfg.GetMetadata().GetName()
	if name == "" {
		name = "ckpt"
	}

	dst := filepath.Join(gpuCRStageDir, fmt.Sprintf("%s-Checkpoint.tar", name))
	if err := stageCheckpointURI(ctx, uri, dst); err != nil {
		return fmt.Errorf("stage checkpoint %q: %w", uri, err)
	}

	log.Infof(ctx, "gpu-cr: staged checkpoint %q -> %s; restoring from local archive", uri, dst)
	cfg.Image = &types.ImageSpec{Image: dst}
	return nil
}

// stageCheckpointURI copies/downloads the checkpoint archive at uri to dst.
// Supported schemes: file, hostpath (local file already on the node), nfs
// (read-only mount + copy), http/https (download). s3 is intentionally not
// implemented; pre-stage and reference with file:// instead.
func stageCheckpointURI(ctx context.Context, uri, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}

	scheme, rest, ok := strings.Cut(uri, "://")
	if !ok {
		// A bare path is treated as a local file.
		return copyLocalFile(uri, dst)
	}

	switch scheme {
	case "file", "hostpath":
		return copyLocalFile("/"+strings.TrimPrefix(rest, "/"), dst)
	case "http", "https":
		return downloadFile(ctx, uri, dst)
	case "nfs":
		return stageFromNFS(ctx, rest, dst)
	case "s3":
		return fmt.Errorf("s3:// staging not implemented; pre-stage and use file://")
	default:
		return fmt.Errorf("unsupported checkpoint-uri scheme %q", scheme)
	}
}

func copyLocalFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("open %s: %w", src, err)
	}
	defer in.Close()

	return writeTo(dst, in)
}

func downloadFile(ctx context.Context, url, dst string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}

	return writeTo(dst, resp.Body)
}

// stageFromNFS mounts <server>:<dir> read-only and copies the named file.
// rest is "<server>/<export-dir>/<file>".
func stageFromNFS(ctx context.Context, rest, dst string) error {
	server, path, ok := strings.Cut(rest, "/")
	if !ok {
		return fmt.Errorf("malformed nfs uri: nfs://%s", rest)
	}

	path = "/" + path
	mnt, err := os.MkdirTemp("", "gpu-cr-nfs")
	if err != nil {
		return err
	}
	defer os.RemoveAll(mnt)

	src := fmt.Sprintf("%s:%s", server, filepath.Dir(path))
	if out, err := exec.CommandContext(ctx, "mount", "-t", "nfs", "-o", "ro,soft,timeo=100", src, mnt).CombinedOutput(); err != nil {
		return fmt.Errorf("mount %s: %v (%s)", src, err, strings.TrimSpace(string(out)))
	}
	defer func() { _ = exec.Command("umount", mnt).Run() }()

	return copyLocalFile(filepath.Join(mnt, filepath.Base(path)), dst)
}

func writeTo(dst string, r io.Reader) error {
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := io.Copy(out, r); err != nil {
		return err
	}

	return out.Sync()
}
