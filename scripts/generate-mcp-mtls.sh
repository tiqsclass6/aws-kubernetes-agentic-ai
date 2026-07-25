#!/usr/bin/env bash
set -euo pipefail

for command in openssl kubectl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: ${command} is required but was not found in PATH." >&2
    exit 1
  fi
done

for namespace in mcp-gateway ai-agents; do
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "ERROR: namespace '${namespace}' does not exist." >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d)"

trap 'rm -rf "${WORK_DIR}"' EXIT

chmod 700 "${WORK_DIR}"

cat > "${WORK_DIR}/server.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = distinguished_name
req_extensions = request_extensions

[distinguished_name]
CN = mcp-gateway.mcp-gateway.svc.cluster.local
O = agentic-security-lab
OU = mcp-gateway

[request_extensions]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = mcp-gateway
DNS.2 = mcp-gateway.mcp-gateway
DNS.3 = mcp-gateway.mcp-gateway.svc
DNS.4 = mcp-gateway.mcp-gateway.svc.cluster.local
EOF

create_client_config() {
  local common_name="$1"
  local output_file="$2"

  cat > "${output_file}" <<EOF
[req]
prompt = no
distinguished_name = distinguished_name
req_extensions = request_extensions

[distinguished_name]
CN = ${common_name}
O = agentic-security-lab
OU = ai-agents

[request_extensions]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
}

issue_client_certificate() {
  local common_name="$1"
  local basename="$2"
  local config_file="${WORK_DIR}/${basename}.cnf"

  create_client_config \
    "${common_name}" \
    "${config_file}"

  openssl genrsa \
    -out "${WORK_DIR}/${basename}.key" \
    2048

  openssl req \
    -new \
    -sha256 \
    -key "${WORK_DIR}/${basename}.key" \
    -config "${config_file}" \
    -out "${WORK_DIR}/${basename}.csr"

  openssl x509 \
    -req \
    -sha256 \
    -days 365 \
    -in "${WORK_DIR}/${basename}.csr" \
    -CA "${WORK_DIR}/client-ca.crt" \
    -CAkey "${WORK_DIR}/client-ca.key" \
    -CAcreateserial \
    -extensions request_extensions \
    -extfile "${config_file}" \
    -out "${WORK_DIR}/${basename}.crt"

  openssl verify \
    -CAfile "${WORK_DIR}/client-ca.crt" \
    "${WORK_DIR}/${basename}.crt"
}

echo "Generating MCP gateway server CA and certificate..."

openssl genrsa \
  -out "${WORK_DIR}/server-ca.key" \
  4096

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 3650 \
  -key "${WORK_DIR}/server-ca.key" \
  -subj "/CN=agentic-mcp-server-ca/O=agentic-security-lab" \
  -out "${WORK_DIR}/server-ca.crt"

openssl genrsa \
  -out "${WORK_DIR}/server.key" \
  2048

openssl req \
  -new \
  -sha256 \
  -key "${WORK_DIR}/server.key" \
  -config "${WORK_DIR}/server.cnf" \
  -out "${WORK_DIR}/server.csr"

openssl x509 \
  -req \
  -sha256 \
  -days 365 \
  -in "${WORK_DIR}/server.csr" \
  -CA "${WORK_DIR}/server-ca.crt" \
  -CAkey "${WORK_DIR}/server-ca.key" \
  -CAcreateserial \
  -extensions request_extensions \
  -extfile "${WORK_DIR}/server.cnf" \
  -out "${WORK_DIR}/server.crt"

openssl verify \
  -CAfile "${WORK_DIR}/server-ca.crt" \
  "${WORK_DIR}/server.crt"

echo "Generating client CA and agent client certificates..."

openssl genrsa \
  -out "${WORK_DIR}/client-ca.key" \
  4096

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 3650 \
  -key "${WORK_DIR}/client-ca.key" \
  -subj "/CN=agentic-mcp-client-ca/O=agentic-security-lab" \
  -out "${WORK_DIR}/client-ca.crt"

# Phase 3 issues a client identity only to the dedicated remediation agent.
issue_client_certificate \
  "remediation-agent" \
  "remediation-agent-client"

kubectl \
  -n mcp-gateway \
  create secret tls \
  mcp-gateway-server-tls \
  --cert="${WORK_DIR}/server.crt" \
  --key="${WORK_DIR}/server.key" \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

kubectl \
  -n mcp-gateway \
  create secret generic \
  mcp-client-ca \
  --from-file=ca.crt="${WORK_DIR}/client-ca.crt" \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

kubectl \
  -n ai-agents \
  create secret tls \
  remediation-agent-client-tls \
  --cert="${WORK_DIR}/remediation-agent-client.crt" \
  --key="${WORK_DIR}/remediation-agent-client.key" \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

kubectl \
  -n ai-agents \
  create secret generic \
  mcp-gateway-server-ca \
  --from-file=ca.crt="${WORK_DIR}/server-ca.crt" \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

kubectl \
  -n mcp-gateway \
  get secret \
  mcp-gateway-server-tls \
  mcp-client-ca

kubectl \
  -n ai-agents \
  delete secret \
  vertex-agent-client-tls \
  --ignore-not-found

kubectl \
  -n ai-agents \
  get secret \
  remediation-agent-client-tls \
  mcp-gateway-server-ca

echo "mTLS secrets created or rotated successfully."
echo "Restart mcp-gateway, mcp-server, and remediation-agent after rotation."