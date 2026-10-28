# ============================================================
# MULTI-CLOUD OIDC FEDERATION LAB
# Auth0 -> AWS IAM and GCP Workload Identity Federation
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ============================================================
# 1. CONFIGURATION VARIABLES
# ============================================================

variable "auth0_domain" {
  type        = string
  default     = "dev-n0sq8f24hbtzdkds.us.auth0.com"
  description = "Auth0 tenant domain without https://"
}

variable "auth0_client_id" {
  type        = string
  default     = "kXfGnvQ85LBKxE8vyK9wyQzvfI8Zroc0"
  description = "Auth0 Native Application client ID"
}

variable "auth0_api_audience" {
  type        = string
  default     = "https://federation-lab.example.com"
  description = "Identifier of the Auth0 custom API"
}

variable "auth0_user_id" {
  type        = string
  default     = "auth0|6ad126e466a456d3b3a501f9"
  description = "Exact sub claim of the Auth0 test user"
}

variable "gcp_project_id" {
  type        = string
  default     = "exalate-project-492211"
  description = "Google Cloud project ID"
}

# ============================================================
# 2. AWS: OIDC PROVIDER AND IAM ROLE
# ============================================================

provider "aws" {
  region = "us-east-1"
}

data "tls_certificate" "auth0" {
  url = "https://${var.auth0_domain}/"
}

resource "aws_iam_openid_connect_provider" "auth0_idp" {
  url = "https://${var.auth0_domain}/"

  # AWS audience configuration for this Auth0 token.
  client_id_list = [
    var.auth0_client_id
  ]

  thumbprint_list = [
    data.tls_certificate.auth0.certificates[0].sha1_fingerprint
  ]
}

resource "aws_iam_role" "devops_federated_role" {
  name = "Auth0-DevOps-Federated-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Federated = aws_iam_openid_connect_provider.auth0_idp.arn
        }

        Action = "sts:AssumeRoleWithWebIdentity"

        Condition = {
          StringEquals = {
            "${var.auth0_domain}/:aud"  = var.auth0_client_id
            "${var.auth0_domain}/:oaud" = var.auth0_api_audience
            "${var.auth0_domain}/:sub"  = var.auth0_user_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.devops_federated_role.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ============================================================
# 3. GCP: PROJECT AND WORKLOAD IDENTITY POOL
# ============================================================

provider "google" {
  project = var.gcp_project_id
  region  = "us-central1"
}

# Retrieve the numeric GCP project number.
data "google_project" "current" {
  project_id = var.gcp_project_id
}

# Create the Workload Identity Pool.
resource "google_iam_workload_identity_pool" "auth0_pool" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "auth0-devops-pool"
  display_name              = "Auth0 DevOps Pool"
  description               = "Federation pool for Auth0 identities"
}

# Configure Auth0 as the pool's OIDC provider.
resource "google_iam_workload_identity_pool_provider" "auth0_provider" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.auth0_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "auth0-oidc-provider"

  display_name = "Auth0 OIDC Provider"

  # Map the external JWT subject to GCP's canonical subject attribute.
  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  # Restrict federation to the intended test user.
  attribute_condition = "assertion.sub == '${var.auth0_user_id}'"

  oidc {
    issuer_uri = "https://${var.auth0_domain}/"

    allowed_audiences = [
      var.auth0_api_audience
    ]
  }
}

# ============================================================
# 4. GCP: FEDERATED SERVICE ACCOUNT
# ============================================================

resource "google_service_account" "devops_sa" {
  project      = var.gcp_project_id
  account_id   = "auth0-devops-sa"
  display_name = "Auth0 Federated DevOps Service Account"
}

# Allow the specified federated subject to impersonate the service account.
resource "google_service_account_iam_member" "pool_impersonation" {
  service_account_id = google_service_account.devops_sa.name
  role               = "roles/iam.workloadIdentityUser"

  member = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.auth0_pool.workload_identity_pool_id}/subject/${var.auth0_user_id}"

  depends_on = [
    google_iam_workload_identity_pool_provider.auth0_provider
  ]
}

# Baseline project-level read-only access.
resource "google_project_iam_member" "sa_viewer_permission" {
  project = var.gcp_project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.devops_sa.email}"
}

# ============================================================
# 5. OUTPUTS
# ============================================================

output "aws_oidc_provider_arn" {
  description = "AWS Auth0 OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.auth0_idp.arn
}

output "aws_federated_role_arn" {
  description = "AWS IAM role ARN for federation"
  value       = aws_iam_role.devops_federated_role.arn
}

output "gcp_project_number" {
  description = "Numeric GCP project number"
  value       = data.google_project.current.number
}

output "gcp_workload_identity_pool_name" {
  description = "GCP Workload Identity Pool resource name"
  value       = google_iam_workload_identity_pool.auth0_pool.name
}

output "gcp_service_account_email" {
  description = "Federated GCP service account email"
  value       = google_service_account.devops_sa.email
}