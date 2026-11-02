# Multi-Cloud Identity Federation with Auth0, AWS and Google Cloud

A Terraform-based lab demonstrating centralized identity federation from **Auth0** to **AWS IAM** and **Google Cloud Workload Identity Federation (WIF)**.

The goal is to replace long-lived cloud credentials with short-lived credentials issued after an external identity has been validated.

The repository provisions the AWS and Google Cloud infrastructure. Auth0 applications, APIs/audiences, user-role assignments, Post-Login Actions, and token acquisition are configured separately.

## Architecture

<img width="986" height="867" alt="image" src="https://github.com/user-attachments/assets/d475b837-ac36-4a62-941f-aa572590a18a" />

### Federation flow

1. The user authenticates with Auth0.
2. Auth0 issues a signed token for the requested federation audience/context.
3. AWS STS or Google STS validates the token against the configured issuer and trust rules.
4. The cloud provider issues temporary credentials or permits service-account impersonation.
5. AWS IAM policies or Google Cloud IAM roles determine what the resulting identity can actually do.

No permanent AWS access keys or Google service-account private keys are required for the federation flow.

## Why separate AWS audiences for read and write?

The AWS integration uses two distinct audience values:

* `https://aws-readonly.example.com` — intended for the read-only IAM role.
* `https://aws-write.example.com` — intended for the S3-scoped write IAM role.

The purpose is to give each role a separate token audience and trust context. The read-only role's trust policy accepts only the read-only audience, while the write role's trust policy accepts only the write audience. A token issued for one path therefore does not satisfy the other role's audience condition.

**Why this approach?**

AWS's third-party OIDC federation integration through IAM uses OIDC ID-token semantics. Although the `AssumeRoleWithWebIdentity` API has broader token documentation, AWS's OAuth access-token `ProviderId` integration is limited to specific providers (Login with Amazon and Facebook), rather than arbitrary third-party OIDC providers such as Auth0.

Consequently, this lab uses Auth0-issued OIDC tokens and separates the AWS read-only and write-access paths through distinct audiences.

The AWS trust policies use two condition keys:

* `<auth0-domain>:aud` — compared with the Auth0 application client ID.
* `<auth0-domain>:oaud` — compared with the role-specific audience.

When an OIDC token contains an `azp` claim, AWS maps `azp` to its `aud` condition key and the original JWT `aud` to `oaud`.

The Auth0 Post-Login Action must enforce the role-to-audience relationship: a user without write authorization must not be able to obtain a token accepted by the write role.

**Important:** The current AWS trust policies do not directly inspect the namespaced Auth0 roles claim. Audience separation and IAM permissions provide different layers of the access-control model.

> Before reproducing the lab, inspect the actual token claims issued by your Auth0 tenant and confirm that `iss`, `aud`, `azp` (when present), and the AWS `oaud` mapping match the trust policies.

## Auth0 and claim model

The Terraform configuration uses these audience identifiers as defaults/examples:

| Variable                | Example value                        | Used for           |
| ----------------------- | ------------------------------------ | ------------------ |
| `auth0_api_audience`    | `https://federation-lab.example.com` | Google Cloud WIF   |
| `aws_readonly_audience` | `https://aws-readonly.example.com`   | AWS read-only role |
| `aws_write_audience`    | `https://aws-write.example.com`      | AWS write role     |

For Google Cloud, the token must contain the namespaced claim:

```json
{
  "https://identity.example.com/roles": ["read-only"]
}
```

The accepted role values are `read-only` and `write-access`.

Terraform maps the Auth0 subject to `google.subject` and maps the **first** value in the roles array to `attribute.roles`. The provider condition rejects tokens with an empty roles array or an unapproved first role.

Auth0 configuration is external to this Terraform project. Configure the application, API audiences, user-role assignments, and a Post-Login Action that adds the namespaced roles claim to the token used for Google federation. The Action must also enforce the AWS audience-to-role rule described above.

## What Terraform creates

### AWS

| Resource                      | Purpose                                                                                    |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| IAM OIDC provider             | Registers the Auth0 issuer with AWS IAM.                                                   |
| `Auth0-DevOps-Federated-Role` | Legacy compatibility role restricted by the configured Auth0 subject and general audience. |
| `Auth0-DevOps-ReadOnly-Role`  | Audience-specific role with AWS-managed `ReadOnlyAccess`.                                  |
| `Auth0-DevOps-Write-Role`     | Audience-specific role with permissions scoped to the lab S3 bucket.                       |
| S3 lab bucket                 | Dedicated test bucket with public access blocked and default SSE-S3 encryption.            |

The write role's inline policy permits:

* `s3:ListBucket` on the bucket.
* `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on objects in that bucket.

It does not grant general AWS write access.

### Google Cloud

| Resource                                   | Purpose                                                                                                         |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Workload Identity Pool `auth0-devops-pool` | Groups federated external identities.                                                                           |
| OIDC provider `auth0-oidc-provider`        | Trusts the Auth0 issuer, checks the allowed audience, and evaluates the role attribute condition.               |
| Service account `auth0-devops-sa`          | Impersonated by the `read-only` principal set; granted project-level `roles/viewer`.                            |
| Service account `auth0-write-access`       | Impersonated by the `write-access` principal set; currently has no resource-level or project-level permissions. |

Being allowed to impersonate `auth0-write-access` does not grant permission to modify Google Cloud resources. Permissions must be granted separately and deliberately.

## Prerequisites

* Terraform CLI compatible with the provider constraints (`aws ~> 5.0`, `google ~> 5.0`, `tls ~> 4.0`).
* AWS CLI v2 and credentials for the intended AWS account.
* Google Cloud CLI and a project where you can manage Workload Identity Federation, service accounts, and IAM bindings.
* An Auth0 tenant where you can configure applications, APIs, users, roles, and Actions.
* Required Google Cloud APIs enabled, including IAM, Security Token Service, IAM Service Account Credentials, and Cloud Resource Manager.

The AWS provider is configured for `us-east-1`. The Google provider uses `us-central1`; the Workload Identity Pool and provider are global resources.

## Configure and deploy

### 1. Configure Auth0

Create or select an Auth0 application and configure the federation audiences shown above.

Create the `read-only` and `write-access` roles, assign them to test users, and publish a Post-Login Action that:

* Adds `https://identity.example.com/roles` to the token used for Google federation.
* Ensures only users with the appropriate role can request the AWS read-only or write audience.

Confirm the claims in a locally decoded token before proceeding. Decoding a JWT does not validate its signature; AWS and Google perform signature validation during federation.

### 2. Configure Terraform variables

The current Terraform source contains environment-specific defaults. Replace them or override them in a local `terraform.tfvars` file.

```hcl
auth0_domain           = "YOUR_TENANT_REGION.auth0.com"
auth0_client_id        = "YOUR_AUTH0_CLIENT_ID"
auth0_api_audience     = "https://federation-lab.example.com"
aws_readonly_audience  = "https://aws-readonly.example.com"
aws_write_audience     = "https://aws-write.example.com"
auth0_user_id          = "auth0|YOUR_TEST_USER_ID"
gcp_project_id         = "YOUR_GCP_PROJECT_ID"
aws_s3_lab_bucket_name = "your-unique-lab-bucket-name"
```

S3 bucket names must be globally unique.

Keep `terraform.tfvars`, tokens, generated credential files, and cloud credentials out of source control. Never store client secrets or private keys in Terraform source.

### 3. Authenticate and deploy

Authenticate to AWS using your approved method, then configure Google Application Default Credentials:

```bash
gcloud auth application-default login
```

Run the following commands from the directory containing the Terraform configuration:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Review the plan before applying it. Confirm the AWS account, Google project, Auth0 issuer, audience values, role names, and S3 bucket name.

The current Terraform outputs include:

* AWS OIDC provider ARN.
* Legacy AWS role ARN.
* Google Cloud project number.
* Workload Identity Pool name.
* Read-only Google service-account email.
* Write-access Google service-account email.

The two newer AWS role ARNs and S3 bucket name are not currently exposed as Terraform outputs.

## Verification

### AWS

Check that the provider and roles exist:

```bash
aws iam list-open-id-connect-providers

aws iam get-role \
  --role-name Auth0-DevOps-ReadOnly-Role

aws iam get-role \
  --role-name Auth0-DevOps-Write-Role
```

Obtain the appropriate Auth0 token using the configured flow, then exchange it with STS:

```bash
aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::<AWS_ACCOUNT_ID>:role/Auth0-DevOps-ReadOnly-Role" \
  --role-session-name "Auth0ReadOnlyTest" \
  --web-identity-token "$AUTH0_TOKEN" \
  --duration-seconds 3600
```

Use the returned temporary credentials in an isolated test profile or shell and verify the identity:

```bash
aws sts get-caller-identity
```

Repeat with the write-audience token and `Auth0-DevOps-Write-Role`.

The write role should be able to manage objects only in the dedicated lab bucket, unless other policies grant additional access.

### Google Cloud

Inspect the Workload Identity Pool:

```bash
gcloud iam workload-identity-pools describe auth0-devops-pool \
  --location="global" \
  --project="YOUR_GCP_PROJECT_ID"
```

Inspect its OIDC provider:

```bash
gcloud iam workload-identity-pools providers describe auth0-oidc-provider \
  --workload-identity-pool="auth0-devops-pool" \
  --location="global" \
  --project="YOUR_GCP_PROJECT_ID"
```

For an end-to-end test:

1. Obtain a fresh Auth0 token for the GCP audience.
2. Create an external-account credential configuration referencing the pool/provider and the read-only service account.
3. Authenticate using that credential configuration.
4. Test a project Viewer operation.

The read-only identity should be able to perform project Viewer operations.

The write-access identity can be impersonated, but resource write operations should be denied because no resource permissions are currently assigned to that service account.

### Expected access tests

| Test                                                              | Expected result                           |
| ----------------------------------------------------------------- | ----------------------------------------- |
| Read-only AWS token assumes the read-only role                    | Allow                                     |
| Read-only AWS token assumes the write role                        | Deny — audience mismatch                  |
| Write AWS token assumes the write role                            | Allow                                     |
| Write role writes to the dedicated lab bucket                     | Allow                                     |
| Write role writes to an unrelated bucket                          | Deny, unless another policy grants access |
| Google token has no roles claim or an unapproved first role       | Deny                                      |
| Google `read-only` principal impersonates `auth0-devops-sa`       | Allow                                     |
| Google `read-only` principal impersonates `auth0-write-access`    | Deny                                      |
| Google `write-access` principal impersonates `auth0-write-access` | Allow                                     |
| Google write-access service account modifies a resource           | Deny under the current configuration      |

## Security considerations

This is a learning and portfolio lab, not a production-ready landing zone.

The implementation demonstrates:

* Federated identity instead of requiring long-lived cloud access keys for end users.
* Separate AWS audiences for read-only and write access.
* Google Workload Identity Federation with attribute-based access control.
* Separate service accounts for Google read-only and write-access identities.
* AWS write permissions scoped to a dedicated S3 bucket.
* S3 public-access blocking and default SSE-S3 encryption.

Before production use, consider the following:

* **AWS least privilege:** `ReadOnlyAccess` is a broad AWS-managed policy. Use narrower service-specific policies where practical.
* **AWS trust policies:** The two audience-specific roles do not currently pin an Auth0 `sub` or directly evaluate the namespaced roles claim. Their security depends partly on the Auth0 Action correctly controlling audience issuance.
* **Legacy role:** Remove `Auth0-DevOps-Federated-Role` after the newer audience-specific roles have been validated and the compatibility path is no longer needed.
* **Google write permissions:** The write-access service account currently has no resource permissions. Grant only the permissions required for a defined task.
* **Role mapping:** Google currently evaluates only the first role in the roles array. Ensure Auth0 emits the intended role at index `0`.
* **Token security:** Access tokens and ID tokens are bearer credentials. Never commit tokens, expose them in logs, or include them in screenshots.
* **Terraform state:** Protect state with encryption and restricted access.
* **Environment separation:** Use separate applications, audiences, pools/providers, service accounts, and state for development, staging, and production.
* **Auditability:** Enable and retain AWS CloudTrail and Google Cloud audit logs according to the environment's requirements.

### Authentication versus authorization

Auth0 authenticating a user proves an identity to the relying system. It does not automatically grant permission to perform cloud operations.

Access depends on several independent checks:

1. Auth0 issues an appropriately scoped token.
2. The cloud federation provider accepts the issuer, signature, audience, and required claims.
3. The AWS role trust policy or Google service-account impersonation binding authorizes the federated identity.
4. The resulting AWS role or Google service account has the required resource permissions.

Each layer must be independently reviewed and tested.

## Current implementation boundaries

The following are deliberate boundaries of the current Terraform configuration:

* Auth0 users, roles, APIs, application settings, and Post-Login Actions are managed outside Terraform.
* Terraform creates the AWS identity provider and IAM roles but does not create Auth0 tokens or token-acquisition scripts.
* Terraform creates Google Workload Identity Federation resources but does not generate external-account credential files for individual users.
* The legacy AWS role uses a fixed Auth0 subject variable. The two newer AWS roles are audience-specific and do not currently pin a subject.
* The AWS write role is limited to the dedicated S3 lab bucket by its inline policy.
* The Google write-access service account supports federation and impersonation but has no resource permissions.
* Terraform outputs the legacy AWS role ARN, not the two newer AWS role ARNs or the S3 bucket name.
* S3 public access is blocked and SSE-S3 encryption is enabled. Versioning, lifecycle
