# OCI hooks (optional)

The shim performs the GPU restore steps inline after `crun restore`, so no OCI
hook is required for the reference flow. If you prefer to decouple the GPU steps
from the runtime wrapper, you can instead register a `poststart` hook that calls
`runtime/lib/gpu-restore.sh` with the container PID. Kept here as an integration
point; not wired by default.
