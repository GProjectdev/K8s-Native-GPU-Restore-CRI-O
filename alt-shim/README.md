# alt-shim — fork-free alternative (less robust)

This is the original approach: a CRI-O OCI **runtime handler** (`gpu-cr-restore`
RuntimeClass) that wraps `crun` and converts a restore-annotated `create` into a
`crun restore`, then runs the GPU restore inline.

It needs no CRI-O rebuild, but it drives restore *behind* CRI-O's back, so conmon
/ sandbox / kubelet-status handling is fragile across CRI-O versions. Prefer the
patched Custom CRI-O in the repo root. Kept here for environments that can't
rebuild CRI-O.

Install: `sudo ./install-crio-runtime.sh` (after `kubectl apply -f runtimeclass.yaml`).
