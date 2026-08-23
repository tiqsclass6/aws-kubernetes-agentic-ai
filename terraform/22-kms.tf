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

resource "google_kms_crypto_key" "lab_cmek" {
  name     = var.lab_cmek_key_id
  key_ring = google_kms_key_ring.governance.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  # Crypto keys are only scheduled for destroy, not removed. A 409 on apply
  # means import it: bash scripts/03-adopt-retained-gcp.sh
  destroy_scheduled_duration = "86400s"
}

# Destroyed/scheduled versions cannot encrypt. A new ENABLED version is not
# primary until updatePrimaryVersion runs (gcloud / adopt script).
resource "google_kms_crypto_key_version" "lab_cmek" {
  crypto_key      = google_kms_crypto_key.lab_cmek.id
  deletion_policy = "ABANDON"
}

resource "terraform_data" "lab_cmek_primary" {
  input = google_kms_crypto_key_version.lab_cmek.id

  provisioner "local-exec" {
    command = "gcloud kms keys update ${var.lab_cmek_key_id} --location=${var.region} --keyring=${var.kms_keyring_id} --project=${var.project_id} --primary-version=${basename(google_kms_crypto_key_version.lab_cmek.id)}"
  }
}

data "google_bigquery_default_service_account" "this" {
  project = var.project_id

  depends_on = [google_project_service.bigquery]
}

data "google_storage_project_service_account" "this" {
  project = var.project_id

  depends_on = [google_project_service.storage]
}

resource "google_kms_crypto_key_iam_member" "lab_cmek_encrypters" {
  for_each = {
    bigquery = "serviceAccount:${data.google_bigquery_default_service_account.this.email}"
    gcs      = "serviceAccount:${data.google_storage_project_service_account.this.email_address}"
  }

  crypto_key_id = google_kms_crypto_key.lab_cmek.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
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
