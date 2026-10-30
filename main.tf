# ============================================================
# MULTI-CLOUD IDENTITY FEDERATION
# Auth0 -> AWS IAM and Google Cloud
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
# 1. CONFIGURATION
# ============================================================

variable "auth0_domain" {
  type        = string
  default     = "dev-n0sq8f24hbtzdkds.us.auth0.com"
  description = "Auth0 tenant domain without https://"
}

variable "auth0_client_id" {
  type        = string
  default     = "kXfGnvQ85LBKxE8vyK9wyQzvfI8Zroc0"
  description = "Auth0 application client ID"
}

variable "auth0_api_audience" {
  type        = string
  default     = "https://federation-lab.example.com"
  description = "Auth0 API audience"
}

variable "aws_readonly_audience" {
  type        = string
  default     = "https://aws-readonly.example.com"
  description = "Auth0 API audience for AWS read-only federation"
}

variable "aws_write_audience" {
  type        = string
  default     = "https://aws-write.example.com"
  description = "Auth0 API audience for AWS write federation"
}

variable "auth0_user_id" {
  type        = string
  default     = "auth0|6ae248b0db18ddef3a1f1706"
  description = "Existing Auth0 subject permitted by the AWS role"
}

variable "gcp_project_id" {
  type        = string
  default     = "exalate-project-492211"
  description = "Google Cloud project ID"
}

# ============================================================
# 2. AWS IDENTITY FEDERATION
# ============================================================

provider "aws" {
  region = "us-east-1"
}

# Read the Auth0 issuer's TLS certificate.
data "tls_certificate" "auth0" {
  url = "https://${var.auth0_domain}/"
}

# Register Auth0 as an identity provider in AWS IAM.
resource "aws_iam_openid_connect_provider" "auth0_idp" {
  url = "https://${var.auth0_domain}/"

  client_id_list = [
    var.auth0_client_id
  ]

  thumbprint_list = [
    data.tls_certificate.auth0.certificates[0].sha1_fingerprint
  ]
}

# Create an AWS role restricted to the configured Auth0 user.
# ============================================================
# AWS FEDERATED IAM ROLES
# ============================================================

# Temporary compatibility role. Retain until both new roles
# have been tested successfully.
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

# AWS read-only federation role.
resource "aws_iam_role" "aws_readonly" {
  name = "Auth0-DevOps-ReadOnly-Role"

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
            "${var.auth0_domain}/:oaud" = var.aws_readonly_audience
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "aws_readonly" {
  role       = aws_iam_role.aws_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# AWS write federation role.
resource "aws_iam_role" "aws_write" {
  name = "Auth0-DevOps-Write-Role"

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
            "${var.auth0_domain}/:oaud" = var.aws_write_audience
          }
        }
      }
    ]
  })
}

# Placeholder for narrowly scoped write permissions.
# No write permissions are granted until a specific resource
# and permission set are defined.

# ============================================================
# 3. GOOGLE CLOUD WORKLOAD IDENTITY FEDERATION
# ============================================================

provider "google" {
  project = var.gcp_project_id
  region  = "us-central1"
}

# Retrieve the numeric project number for IAM principal identifiers.
data "google_project" "current" {
  project_id = var.gcp_project_id
}

# Create a pool that groups federated external identities.
resource "google_iam_workload_identity_pool" "auth0_pool" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "auth0-devops-pool"
  display_name              = "Auth0 DevOps Pool"
  description               = "Workload identity federation with Auth0"
}

# Trust Auth0 tokens and map the subject and role into GCP attributes.
resource "google_iam_workload_identity_pool_provider" "auth0_provider" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.auth0_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "auth0-oidc-provider"
  display_name                       = "Auth0 OIDC Provider"

  # Map the Auth0 identity and role into Google Cloud attributes.
  attribute_mapping = {
    "google.subject"  = "assertion.sub"
    "attribute.roles" = "assertion['https://identity.example.com/roles'][0]"
  }

  # Accept only tokens with an approved Auth0 role.
  attribute_condition = <<-EOT
    assertion['https://identity.example.com/roles'].size() > 0 &&
    assertion['https://identity.example.com/roles'][0] in ["read-only", "write-access"]
  EOT

  oidc {
    issuer_uri = "https://${var.auth0_domain}/"

    allowed_audiences = [
      var.auth0_api_audience
    ]
  }
}

# ============================================================
# 4. GOOGLE CLOUD SERVICE ACCOUNTS
# ============================================================

# Create the service account for read-only federated users.
resource "google_service_account" "devops_sa" {
  project      = var.gcp_project_id
  account_id   = "auth0-devops-sa"
  display_name = "Auth0 Federated DevOps Service Account"
}

# Create a separate service account for write-access federated users.
resource "google_service_account" "write_access_sa" {
  project      = var.gcp_project_id
  account_id   = "auth0-write-access"
  display_name = "Auth0 Write Access"
}

# Allow the read-only role to impersonate the read-only service account.
resource "google_service_account_iam_member" "pool_impersonation" {
  service_account_id = google_service_account.devops_sa.name
  role               = "roles/iam.workloadIdentityUser"

  member = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.auth0_pool.workload_identity_pool_id}/attribute.roles/read-only"

  depends_on = [
    google_iam_workload_identity_pool_provider.auth0_provider
  ]
}

# Allow the write-access role to impersonate the write service account.
resource "google_service_account_iam_member" "pool_impersonation_write_access" {
  service_account_id = google_service_account.write_access_sa.name
  role               = "roles/iam.workloadIdentityUser"

  member = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.auth0_pool.workload_identity_pool_id}/attribute.roles/write-access"

  depends_on = [
    google_iam_workload_identity_pool_provider.auth0_provider
  ]
}

# Give only the read-only service account project-level Viewer access.
resource "google_project_iam_member" "sa_viewer_permission" {
  project = var.gcp_project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.devops_sa.email}"
}

# ============================================================
# 5. OUTPUTS
# ============================================================

# Print the AWS OIDC provider ARN.
output "aws_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.auth0_idp.arn
  description = "AWS Auth0 OIDC provider ARN"
}

# Print the AWS federated role ARN.
output "aws_federated_role_arn" {
  value       = aws_iam_role.devops_federated_role.arn
  description = "AWS federated read-only role ARN"
}

# Print the Google Cloud project number.
output "gcp_project_number" {
  value       = data.google_project.current.number
  description = "Google Cloud project number"
}

# Print the Workload Identity Pool resource name.
output "gcp_workload_identity_pool_name" {
  value       = google_iam_workload_identity_pool.auth0_pool.name
  description = "Google Cloud Workload Identity Pool"
}

# Print the read-only service account email.
output "gcp_service_account_email" {
  value       = google_service_account.devops_sa.email
  description = "Federated Google Cloud read-only service account"
}

# Print the write-access service account email.
output "gcp_write_access_service_account_email" {
  value       = google_service_account.write_access_sa.email
  description = "Federated Google Cloud write-access service account"
}

# ============================================================
# S3 FEDERATION LAB
# ============================================================

variable "aws_s3_lab_bucket_name" {
  description = "Dedicated S3 bucket for the Auth0 AWS federation lab."
  type        = string
  default     = "auth0-federation-lab-223532248615-20261029"
}

# Dedicated lab bucket
resource "aws_s3_bucket" "federation_lab" {
  bucket = var.aws_s3_lab_bucket_name

  tags = {
    Purpose     = "Auth0 OIDC Federation Lab"
    Environment = "Lab"
    ManagedBy   = "Terraform"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "federation_lab" {
  bucket = aws_s3_bucket.federation_lab.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable server-side encryption using SSE-S3
resource "aws_s3_bucket_server_side_encryption_configuration" "federation_lab" {
  bucket = aws_s3_bucket.federation_lab.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Grant the AWS write role access only to the dedicated lab bucket
resource "aws_iam_role_policy" "aws_write_s3_lab" {
  name = "Auth0-DevOps-Write-S3-Lab-Policy"
  role = aws_iam_role.aws_write.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ListDedicatedLabBucket"
        Effect = "Allow"

        Action = [
          "s3:ListBucket"
        ]

        Resource = aws_s3_bucket.federation_lab.arn
      },
      {
        Sid    = "ManageObjectsInDedicatedLabBucket"
        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]

        Resource = "${aws_s3_bucket.federation_lab.arn}/*"
      }
    ]
  })
}