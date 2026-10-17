#!/usr/bin/env bash
# End-to-end check of the setup on a local Docker host:
#   1. two daemons (team-a, team-b), each with its own CA and network
#   2. a team-a client builds an image over mTLS
#   3. the same team-a certificate is rejected by team-b's daemon
# Leaves nothing behind (containers, networks, volumes and temp certs are removed).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
CLIENT_IMAGE=moby/buildkit:v0.17.2

cleanup() {
  docker rm -f registry-team-a >/dev/null 2>&1 || true
  for g in team-a team-b; do
    [[ -d "$WORK/$g" ]] && (cd "$WORK/$g" && GROUP=$g docker compose down -v >/dev/null 2>&1 || true)
  done
  rm -rf -- "$WORK"
}
trap cleanup EXIT

for g in team-a team-b; do
  cp -r buildkitd "$WORK/$g"
  (cd "$WORK/$g" && ./gen-certs.sh "$g" >/dev/null && GROUP=$g docker compose up -d --wait >/dev/null 2>&1)
  echo "ok: buildkitd-$g is healthy"
done

buildctl() { # buildctl <network> <certs-dir> <daemon> args...
  local net=$1 certs=$2 daemon=$3; shift 3
  docker run --rm --network "$net" --entrypoint buildctl \
    -v "$certs:/certs:ro" -v "$PWD/test/app:/src:ro" "$CLIENT_IMAGE" \
    --addr "tcp://$daemon:1234" --tlscacert /certs/ca.pem \
    --tlscert /certs/client.pem --tlskey /certs/client-key.pem "$@"
}

buildctl team-a-ci "$WORK/team-a/certs" buildkitd-team-a \
  build --frontend dockerfile.v0 --local context=/src --local dockerfile=/src \
  --output type=oci,dest=/dev/null >/dev/null 2>&1
echo "ok: team-a built the test image over mTLS"

# Same flags as templates/buildkit-build.yml, against a throwaway registry on the group network
# (plain HTTP here, hence registry.insecure=true).
docker run -d --rm --name registry-team-a --network team-a-ci registry:2 >/dev/null
reg=registry-team-a:5000/app
buildctl team-a-ci "$WORK/team-a/certs" buildkitd-team-a \
  build --frontend dockerfile.v0 --local context=/src --local dockerfile=/src --opt filename=Dockerfile \
  --import-cache "type=registry,ref=$reg:buildcache,registry.insecure=true" \
  --export-cache "type=registry,ref=$reg:buildcache,mode=max,registry.insecure=true" \
  --output "type=image,name=$reg:test,push=true,registry.insecure=true" >/dev/null 2>&1
tags=$(docker run --rm --network team-a-ci --entrypoint wget "$CLIENT_IMAGE" -qO- http://registry-team-a:5000/v2/app/tags/list)
grep -q '"test"' <<<"$tags" && grep -q '"buildcache"' <<<"$tags" \
  || { echo "FAIL: image or cache missing in registry: $tags" >&2; exit 1; }
echo "ok: image and build cache pushed to the registry"

# team-a's client certificate, but trusting team-b's server so only client auth is tested.
mixed="$WORK/mixed"; mkdir "$mixed"
cp "$WORK/team-b/certs/ca.pem" "$mixed/ca.pem"
cp "$WORK/team-a/certs/client.pem" "$WORK/team-a/certs/client-key.pem" "$mixed/"
chmod 644 "$mixed"/*
if out=$(buildctl team-b-ci "$mixed" buildkitd-team-b debug workers 2>&1); then
  echo "FAIL: team-b accepted team-a's certificate" >&2; exit 1
fi
if ! grep -qiE 'certificate|tls' <<<"$out"; then
  echo "FAIL: team-b refused, but not because of the certificate:" >&2; echo "$out" >&2; exit 1
fi
echo "ok: team-b rejected team-a's client certificate"
echo "all checks passed"
