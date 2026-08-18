package main

import rego.v1

approved_registry := "us-central1-docker.pkg.dev/class-6-5-tiqs/vertex-agent-lab/"

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

pod_spec := input.spec.template.spec if input.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}
pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

containers := object.get(pod_spec, "containers", []) if input.kind in workload_kinds

is_project_image(image) if startswith(image, approved_registry)

is_platform_image(image) if startswith(image, "gke.gcr.io/")
is_platform_image(image) if startswith(image, "gcr.io/gke-release/")
is_platform_image(image) if startswith(image, "registry.k8s.io/")

is_opa_image(image) if startswith(image, "openpolicyagent/opa:")

# Exact tags only — not repository prefixes.
vendor_images := {
  "nginx:1.27.4-alpine",          # manifests/mcp-gateway-deployment.yaml
  "postgres:16-alpine",           # manifests/postgres.yaml
  "aquasec/trivy:0.71.1",         # manifests/trivy-cronjob.yaml
  "prowlercloud/prowler:5.35.0",  # manifests/prowler-cronjob.yaml
}

approved_image(image) if is_project_image(image)
approved_image(image) if is_platform_image(image)
approved_image(image) if is_opa_image(image)
approved_image(image) if image in vendor_images

# Official postgres image must start as root. See manifests/postgres.yaml.
is_permitted_to_run_as_root if {
  input.kind == "Deployment"
  input.metadata.name == "postgres"
}

deny contains msg if {
  input.kind in workload_kinds
  not object.get(object.get(pod_spec, "securityContext", {}), "runAsNonRoot", false)
  not is_permitted_to_run_as_root
  msg := sprintf("%s/%s must set pod securityContext.runAsNonRoot=true", [input.kind, input.metadata.name])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  object.get(object.get(container, "securityContext", {}), "allowPrivilegeEscalation", true)
  msg := sprintf("%s/%s container %s must disable privilege escalation", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  not object.get(object.get(container, "securityContext", {}), "readOnlyRootFilesystem", false)
  msg := sprintf("%s/%s container %s must use a read-only root filesystem", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  count(object.get(object.get(container, "resources", {}), "requests", {})) == 0
  msg := sprintf("%s/%s container %s must define resource requests", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  count(object.get(object.get(container, "resources", {}), "limits", {})) == 0
  msg := sprintf("%s/%s container %s must define resource limits", [input.kind, input.metadata.name, container.name])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  not approved_image(container.image)
  msg := sprintf("%s/%s container %s uses an unapproved image registry: %s", [input.kind, input.metadata.name, container.name, container.image])
}

deny contains msg if {
  input.kind in workload_kinds
  some container in containers
  endswith(container.image, ":latest")
  msg := sprintf("%s/%s container %s must not use the latest tag", [input.kind, input.metadata.name, container.name])
}
