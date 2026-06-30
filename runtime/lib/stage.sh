#!/usr/bin/env bash
# stage.sh — make the Checkpoint.tar referenced by gpu-cr.io/checkpoint-uri
# available on THIS node and unpack it into a CRIU image directory.
#
# This is the explicit "stage checkpoint to target node" step that lets a Pod be
# restored on a node DIFFERENT from where it was checkpointed (migration). For a
# same-node restore the hostpath/file copy is local and cheap.
#
# Supported URI schemes (experimental):
#   file:///abs/path/Checkpoint.tar     local file already on the node
#   hostpath:///var/lib/gcr-checkpoint/<name>.tar   alias of file:// (the
#                                       checkpoint backend dir mounted on nodes)
#   nfs://<server>/<export>/<name>.tar  mounts the export read-only then copies
#   http(s)://host/path/<name>.tar      pulls over the proxy (curl)
#   s3://<bucket>/<key>                 stub; wire up an uploader/mc out of band
#
# Prints the path to the unpacked CRIU image directory on stdout.
gcr_stage_checkpoint() {
  local uri="$1" cid="$2"
  local work; work="$(gcr_rundir "${cid}")"
  local tar="${work}/Checkpoint.tar"
  local scheme="${uri%%://*}" rest="${uri#*://}"

  case "${scheme}" in
    file|hostpath)
      local src="/${rest#/}"
      [ -f "${src}" ] || gcr_die "checkpoint not found on node: ${src} (stage it here first)"
      cp -f "${src}" "${tar}" ;;
    nfs)
      local server="${rest%%/*}" path="/${rest#*/}"
      local mnt="${work}/nfs"; mkdir -p "${mnt}"
      gcr_log "mounting nfs ${server}:$(dirname "${path}")"
      mount -t nfs -o ro,soft,timeo=100 "${server}:$(dirname "${path}")" "${mnt}"
      cp -f "${mnt}/$(basename "${path}")" "${tar}"
      umount "${mnt}" || true ;;
    http|https)
      gcr_log "fetching ${uri}"
      curl -fsSL "${uri}" -o "${tar}" ;;
    s3)
      gcr_die "s3:// staging not implemented; pre-stage the tar and use file:// (uri=${uri})" ;;
    *)
      gcr_die "unsupported checkpoint-uri scheme: ${scheme}" ;;
  esac

  [ -s "${tar}" ] || gcr_die "staged checkpoint is empty: ${tar}"
  local img="${work}/image"
  rm -rf "${img}"; mkdir -p "${img}"
  tar -xf "${tar}" -C "${img}"
  # A kubelet/CRI-O checkpoint tar holds the CRIU images under ./checkpoint/.
  if [ -d "${img}/checkpoint" ]; then echo "${img}/checkpoint"; else echo "${img}"; fi
}
