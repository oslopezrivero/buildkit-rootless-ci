#!/usr/bin/env bash
# Generates a dedicated CA plus server and client certificates for one BuildKit daemon.
# One CA per group: a client certificate issued here is rejected by any other group's daemon.
#
# Usage: ./gen-certs.sh <group> [extra SAN DNS names...]
#   ./gen-certs.sh team-a                      -> certs/ for buildkitd-team-a
#   ./gen-certs.sh team-a buildkit.example.lan -> also valid for that hostname
set -euo pipefail

GROUP="${1:?usage: gen-certs.sh <group> [extra-dns...]}"
shift
DAYS="${CERT_DAYS:-825}"
OUT="$(dirname "$0")/certs"
SERVER_DNS="buildkitd-${GROUP}"

mkdir -p "$OUT"
cd "$OUT"

if [[ -f ca.pem ]]; then
  echo "certs/ already has a CA; remove it first to rotate." >&2
  exit 1
fi

# CA
openssl genrsa -out ca-key.pem 4096 2>/dev/null
openssl req -x509 -new -key ca-key.pem -sha256 -days "$DAYS" \
  -subj "/CN=${GROUP}-buildkit-ca" -out ca.pem

# Server certificate: SANs must match the name the runner uses to reach the daemon.
san="DNS:${SERVER_DNS},DNS:localhost,IP:127.0.0.1"
for dns in "$@"; do san+=",DNS:${dns}"; done
openssl genrsa -out server-key.pem 2048 2>/dev/null
openssl req -new -key server-key.pem -subj "/CN=${SERVER_DNS}" -out server.csr
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -sha256 -days "$DAYS" \
  -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san") -out server.pem 2>/dev/null

# Client certificate: what CI jobs present. Load it into CI variables, never commit it.
openssl genrsa -out client-key.pem 2048 2>/dev/null
openssl req -new -key client-key.pem -subj "/CN=${GROUP}-ci" -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -sha256 -days "$DAYS" \
  -extfile <(printf 'extendedKeyUsage=clientAuth\n') -out client.pem 2>/dev/null

rm -f ./*.csr ./*.srl
# The rootless daemon runs as uid 1000 inside the container and must read its key.
chmod 600 ./*-key.pem
chown 1000:1000 server-key.pem client-key.pem 2>/dev/null || \
  echo "warning: could not chown keys to uid 1000; run as root or adjust permissions" >&2

echo "Certificates for group '${GROUP}' written to ${OUT}"
echo "Keep ca-key.pem offline. Load ca.pem, client.pem and client-key.pem into the group's CI variables."
