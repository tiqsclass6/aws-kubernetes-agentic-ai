resource "google_project_service" "cloudkms" {
  project            = var.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_kms_key_ring" "governance" {
  project  = var.project_id
  name     = var.kms_keyring_id
  location = var.region

  # Key rings cannot be deleted. A 409 on apply means import it:
  # bash scripts/03-adopt-retained-gcp.sh
  depends_on = [google_project_service.cloudkms]
}

resource "google_kms_crypto_key" "approval_signing" {
  name     = var.approval_key_id
  key_ring = google_kms_key_ring.governance.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "EC_SIGN_P256_SHA256"
    protection_level = "SOFTWARE"
  }

  # Crypto keys are only scheduled for destroy, not removed. A 409 on apply
  # means import it: bash scripts/03-adopt-retained-gcp.sh
  destroy_scheduled_duration = "86400s"
}

locals {
  approval_key_version_name = "${google_kms_crypto_key.approval_signing.id}/cryptoKeyVersions/${var.approval_key_version}"
}

resource "google_kms_crypto_key_iam_member" "approval_signers" {
  for_each = toset(var.approval_signer_members)

  crypto_key_id = google_kms_crypto_key.approval_signing.id
  role          = "roles/cloudkms.signerVerifier"
  member        = each.value
}

resource "google_kms_crypto_key_iam_member" "approval_agent_public_key_viewer" {
  crypto_key_id = google_kms_crypto_key.approval_signing.id
  role          = "roles/cloudkms.publicKeyViewer"
  member        = "serviceAccount:${google_service_account.approval_agent.email}"
}
