# Sourced by ensure-job.sh and deploy-container.sh: the image tag is a hash of everything baked
# into the image, so both runners always use the same, up-to-date image.
hash_cmd() { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; }
TAG="deps-$(cat Dockerfile package.json package-lock.json scripts/* | hash_cmd | cut -c1-12)"
IMAGE="rg.${REGION}.scw.cloud/${NAMESPACE}/playwright-e2e:${TAG}"
