#!/usr/bin/env bash
# gen-webhook-certs.sh — provision webhook TLS WITHOUT cert-manager.
# Generates a self-signed CA + serving cert (SAN = the webhook Service DNS),
# creates the tls Secret the orchestrator Pod mounts, and patches the
# MutatingWebhookConfiguration's caBundle so the API server trusts the webhook.
#
# Run AFTER `kubectl apply -f deploy/orchestrator-restore.yaml`.
set -euo pipefail
NS=${NS:-gpu-cr-system}
SVC=${SVC:-gpu-cr-restore-orchestrator-webhook}
SECRET=${SECRET:-gpu-cr-restore-webhook-cert}
WEBHOOK=${WEBHOOK:-gpu-cr-restore-pod}
KUBECTL=${KUBECTL:-kubectl}
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
CN="${SVC}.${NS}.svc"

echo "[certs] generating self-signed CA + serving cert for ${CN}"
openssl genrsa -out "$DIR/ca.key" 2048 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$DIR/ca.key" -subj "/CN=gpu-cr-restore-ca" -days 3650 -out "$DIR/ca.crt" >/dev/null 2>&1
openssl genrsa -out "$DIR/tls.key" 2048 >/dev/null 2>&1
cat > "$DIR/csr.conf" <<CONF
[req]
req_extensions = v3_req
distinguished_name = dn
[dn]
[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = ${SVC}.${NS}.svc
DNS.2 = ${SVC}.${NS}.svc.cluster.local
CONF
openssl req -new -key "$DIR/tls.key" -subj "/CN=${CN}" -out "$DIR/tls.csr" -config "$DIR/csr.conf" >/dev/null 2>&1
openssl x509 -req -in "$DIR/tls.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -out "$DIR/tls.crt" -days 3650 -extensions v3_req -extfile "$DIR/csr.conf" >/dev/null 2>&1

echo "[certs] creating Secret ${NS}/${SECRET}"
$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL -n "$NS" create secret tls "$SECRET" --cert="$DIR/tls.crt" --key="$DIR/tls.key" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

CABUNDLE=$(base64 -w0 < "$DIR/ca.crt" 2>/dev/null || base64 < "$DIR/ca.crt" | tr -d '\n')
echo "[certs] patching caBundle into MutatingWebhookConfiguration/${WEBHOOK}"
$KUBECTL patch mutatingwebhookconfiguration "$WEBHOOK" --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${CABUNDLE}\"}]"

echo "[certs] restarting orchestrator to mount the new cert"
$KUBECTL -n "$NS" rollout restart deploy/gpu-cr-restore-orchestrator >/dev/null 2>&1 || true
echo "[certs] done. Webhook TLS is configured (no cert-manager)."
