#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ui.sh
source "${SCRIPT_DIR}/_ui.sh"

require_command openssl
require_command kubectl

section "07  Generate MCP mTLS certificates"

for namespace in mcp-gateway ai-agents; do
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    die "Namespace '${namespace}' does not exist. Apply manifests/namespaces.yaml first."
  fi
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
chmod 700 "${WORK_DIR}"
log "Working directory: ${WORK_DIR}"

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

create_ca_config() {
  local common_name="$1"
  local output_file="$2"

  cat > "${output_file}" <<EOF
[req]
prompt = no
distinguished_name = distinguished_name
x509_extensions = ca_extensions

[distinguished_name]
CN = ${common_name}
O = agentic-security-lab

[ca_extensions]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
}

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

section "Server CA and gateway certificate"
openssl genrsa \
  -out "${WORK_DIR}/server-ca.key" \
  4096

create_ca_config "agentic-mcp-server-ca" "${WORK_DIR}/server-ca.cnf"

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 3650 \
  -key "${WORK_DIR}/server-ca.key" \
  -config "${WORK_DIR}/server-ca.cnf" \
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
success "Server certificate verified."

section "Client CA and agent client certificates"
openssl genrsa \
  -out "${WORK_DIR}/client-ca.key" \
  4096

create_ca_config "agentic-mcp-client-ca" "${WORK_DIR}/client-ca.cnf"

openssl req \
  -x509 \
  -new \
  -sha256 \
  -days 3650 \
  -key "${WORK_DIR}/client-ca.key" \
  -config "${WORK_DIR}/client-ca.cnf" \
  -out "${WORK_DIR}/client-ca.crt"

# The lab issues a client identity only to the dedicated remediation agent.
issue_client_certificate \
  "remediation-agent" \
  "remediation-agent-client"
success "Client certificate verified."

section "Apply Kubernetes TLS secrets"
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

success_section "mTLS secrets created or rotated"
action "Restart mcp-gateway, mcp-server, and remediation-agent after rotation."
