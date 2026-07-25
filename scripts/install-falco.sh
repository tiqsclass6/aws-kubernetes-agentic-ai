#!/usr/bin/env bash

set -euo pipefail

for command in helm kubectl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo \
      "ERROR: ${command} is required." \
      >&2

    exit 1
  fi
done

ROOT_DIR="$(
  cd "$(
    dirname "${BASH_SOURCE[0]}"
  )/.."

  pwd
)"

helm repo add \
  falcosecurity \
  https://falcosecurity.github.io/charts \
  --force-update

helm repo update \
  falcosecurity

helm upgrade \
  --install \
  falco \
  falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --version 9.1.0 \
  --values "${ROOT_DIR}/helm/falco/values.yaml" \
  --wait \
  --timeout 10m

kubectl rollout status \
  daemonset/falco \
  -n falco \
  --timeout=5m

kubectl get pods \
  -n falco \
  -o wide