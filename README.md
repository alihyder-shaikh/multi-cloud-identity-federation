Multi-Cloud Identity Federation with Auth0, AWS IAM, and Google Cloud

A Terraform-based lab demonstrating how a centralized identity provider can issue OpenID Connect (OIDC) tokens that are exchanged for short-lived cloud credentials in Amazon Web Services (AWS) and Google Cloud Platform (GCP).

The lab uses Auth0 as the identity provider (IdP). Instead of creating long-lived IAM users, AWS access keys, or Google service-account keys for each person, users authenticate through Auth0 and receive access to cloud resources through federated identity.

The implementation covers two different federation models:

AWS: Auth0 is registered as an IAM OIDC identity provider. AWS Security Token Service (STS) evaluates the JWT and the target IAM role's trust policy before issuing temporary role credentials.

Google Cloud: Auth0 is registered as an OIDC provider in a Workload Identity Federation pool. Google Security Token Service validates the external token, maps its claims to Google attributes, and allows approved identities to impersonate designated service accounts.

Terraform provisions the AWS and Google Cloud resources described in this README. Auth0 applications, APIs, user assignments, Post-Login Actions, and the process used to obtain an Auth0 token are configured separately in Auth0 or by the client tooling.

Scope note: This README describes the Terraform configuration in this repository. It does not assume that token-acquisition scripts, Auth0 Action source code, or Google external-account credential configuration files are included unless they are added to the repository separately.

Contents

Architecture

Identity and authorization model

Resources created by Terraform

Prerequisites

Auth0 configuration

Terraform configuration

Deploy the infrastructure

Testing and verification

Expected authorization failures

Security considerations

Current implementation boundaries

Cleanup

References

Architecture

flowchart TB
    U[User / Engineer] -->|Authenticate| A[Auth0]
    A -->|OIDC access token: AWS read-only audience| AWSIDP[AWS IAM OIDC Provider]
    A -->|OIDC access token: AWS write audience| AWSIDP
    A -->|OIDC access token: GCP audience + namespaced roles claim| GCPWIF[Google Workload Identity Federation]

    AWSIDP -->|AssumeRoleWithWebIdentity| STS[AWS STS]
    STS --> AR[Auth0-DevOps-ReadOnly-Role]
    STS --> AW[Auth0-DevOps-Write-Role]
    AR -->|ReadOnlyAccess| AWSR[AWS resources]
    AW -->|S3-scoped permissions| S3[Dedicated federation lab bucket]

    GCPWIF -->|Validate issuer, audience and attributes| GSTS[Google STS]
    GSTS -->|roles = read-only| RO[auth0-devops-sa]
    GSTS -->|roles = write-access| WR[auth0-write-access]
    RO -->|roles/viewer| GCPR[Google Cloud project resources]
    WR -->|No resource role currently granted| GCPW[Google Cloud resources]

Authentication flow

A user authenticates with Auth0 using an application/client flow configured for the lab.

Auth0 issues an OIDC token for the audience requested by the client.

A Post-Login Action adds the namespaced roles claim used by the Google Cloud provider and enforces the lab's audience-to-role policy for AWS token issuance.

For AWS, the client submits the token to AssumeRoleWithWebIdentity. AWS validates the issuer, token signature, audience-related conditions, and the target role trust policy. If those checks pass, AWS returns temporary role credentials.

For Google Cloud, the client presents the Auth0 token to Google Workload Identity Federation. Google validates the issuer, allowed audience, attribute mapping, and attribute condition. An accepted external identity can then impersonate the service account to which its mapped role is bound.

The resulting cloud permissions are determined by the IAM policies attached to the AWS role or Google service account—not simply by the fact that Auth0 authenticated the user.

No long-lived AWS access key or Google service-account private key is required for the federation flow.

Identity and authorization model

The lab uses separate audiences and authorization paths so that a token intended for one cloud access path is not automatically accepted by another.

Auth0 audiences

The Terraform configuration defines three audiences:

Audience

Intended use

Cloud target

https://federation-lab.example.com

General federation token used by the Google provider

Google Cloud

https://aws-readonly.example.com

AWS read-only role assumption

AWS IAM

https://aws-write.example.com

AWS write role assumption

AWS IAM

These are example API identifiers used by this lab. They must match the API audiences configured in your own Auth0 tenant and the values supplied to Terraform.

Auth0 roles and custom claims

The Google provider expects the access token to contain this namespaced claim:

{
  "https://identity.example.com/roles": [
    "read-only"
  ]
}

The two role values recognized by the Google provider are:

read-only

write-access

The Terraform mapping reads the first element of the roles array:

"attribute.roles" = "assertion['https://identity.example.com/roles'][0]"

The provider's attribute condition also checks the first element. Therefore, the role expected by the lab must be present at index 0 in the claim array. A token with no roles, or with an unapproved first role, is rejected by the provider condition.

The Auth0 Post-Login Action is an external part of this design. It must add the namespaced roles claim to the access token used for Google federation. It should also enforce the intended relationship between the authenticated user's assigned role and the requested AWS audience. For example, a user who is not authorized for the AWS write path must not be able to obtain a token that the write-role trust policy will accept.

The Terraform configuration does not create Auth0 users, assign Auth0 roles, create Auth0 APIs, or deploy the Post-Login Action.

AWS OIDC claim handling: aud, azp, and oaud

The AWS trust policies use two OIDC condition keys:

:aud is compared with the Auth0 application client ID.

:oaud is compared with the API audience for the specific AWS access path.

When an OIDC token contains an azp claim, AWS maps the azp value to the OIDC provider's aud condition key and maps the token's original aud value to oaud. This distinction matters when constructing trust policies for Auth0 tokens that contain both claims. Inspect the actual JWT issued by your tenant and confirm its claims before changing the trust policy. Do not assume the same mapping for a token shape that does not contain azp.

In this lab, the expected trust-policy pattern is:

StringEquals = {
  "<auth0-domain>/:aud"  = "<auth0-client-id>"
  "<auth0-domain>/:oaud" = "<aws-specific-api-audience>"
}

This audience separation helps prevent a token issued for one relying party or cloud path from being reused against a different role. AWS still evaluates the role's permissions after the trust relationship is satisfied.

Google Workload Identity Federation claim handling

The Google provider uses the following mappings:

attribute_mapping = {
  "google.subject"  = "assertion.sub"
  "attribute.roles" = "assertion['https://identity.example.com/roles'][0]"
}

google.subject receives the Auth0 sub claim, which identifies the external user.

attribute.roles receives the first value in the namespaced roles claim.

The provider accepts a token only when the roles claim contains at least one value and its first value is either read-only or write-access.

Google IAM then uses principalSet bindings to match the mapped role attribute to a service account. This keeps federation admission (the provider's issuer, audience, and attribute checks) separate from resource authorization (the IAM roles granted to the service account).

Resources created by Terraform

AWS resources

Resource

Purpose

Authorization behavior

IAM OIDC identity provider

Registers the Auth0 issuer with AWS IAM

Uses the Auth0 issuer URL, Auth0 client ID, and TLS certificate thumbprint

Auth0-DevOps-Federated-Role

Legacy compatibility role

Requires the configured client ID, general federation audience, and a specific Auth0 subject; has AWS ReadOnlyAccess attached

Auth0-DevOps-ReadOnly-Role

Audience-specific AWS read role

Requires the configured client ID and AWS read-only audience; has AWS ReadOnlyAccess attached

Auth0-DevOps-Write-Role

Audience-specific AWS write role

Requires the configured client ID and AWS write audience; receives a dedicated S3 policy for the lab bucket

S3 federation lab bucket

Resource used to demonstrate narrowly scoped write access

Public access is blocked and default server-side encryption is set to SSE-S3 (AES256)

AWS permission model

Read-only role

The read-only role has the AWS-managed ReadOnlyAccess policy attached. This is a broad read-only managed policy across supported AWS services; it is not limited to the S3 lab bucket.

Write role

The write role receives a Terraform-managed inline policy for the dedicated lab bucket. The policy grants:

Action

Resource

s3:ListBucket

The lab bucket ARN

s3:GetObject

Objects in the lab bucket

s3:PutObject

Objects in the lab bucket

s3:DeleteObject

Objects in the lab bucket

It does not grant general write access to the AWS account. The policy is scoped to the dedicated bucket and its objects.

Google Cloud resources

Resource

Purpose

Authorization behavior

Workload Identity Pool auth0-devops-pool

Logical pool for external identities

Global pool in the configured GCP project

OIDC provider auth0-oidc-provider

Trusts the Auth0 issuer

Restricts the accepted audience and evaluates the roles attribute condition

Service account auth0-devops-sa

Read-only identity for federated users

read-only principal set can impersonate it; it receives project-level roles/viewer

Service account auth0-write-access

Separate write-access identity

write-access principal set can impersonate it; no resource-level permissions are currently granted to it

The Google service-account IAM bindings grant roles/iam.workloadIdentityUser to the matching federated principal sets:

attribute.roles/read-only can impersonate auth0-devops-sa.

attribute.roles/write-access can impersonate auth0-write-access.

The read-only service account is separately granted project-level roles/viewer. The write-access service account is not granted a project role or resource-specific role by this Terraform configuration. Being able to impersonate that service account does not, by itself, grant permission to modify Google Cloud resources.

Prerequisites

Before deploying the lab, prepare the following:

Local tools

Terraform CLI compatible with the provider constraints in the configuration.

AWS CLI v2.

Google Cloud CLI (gcloud).

Git.

An Auth0 tenant with permission to configure applications, APIs, users, roles, and Actions.

AWS account

The AWS identity used by Terraform must be allowed to create and manage:

IAM OIDC identity providers.

IAM roles and role trust policies.

Managed-policy attachments and inline role policies.

S3 buckets, public-access blocks, and bucket encryption settings.

The AWS CLI must be authenticated to the intended AWS account before Terraform is run.

Google Cloud project

The Google identity used by Terraform must be allowed to manage Workload Identity Pools and providers, service accounts, IAM bindings, and project IAM policy bindings in the target project. The required Google APIs must be enabled for the project. These commonly include IAM, Security Token Service, IAM Service Account Credentials, and Cloud Resource Manager APIs.

Use the project ID in Terraform. The provider obtains the numeric project number from Google Cloud for the principalSet member identifiers.

Auth0 tenant

You need:

An Auth0 issuer/domain.

An Auth0 application client ID.

An API configured for each audience used by the federation flows.

Auth0 users with the intended roles assigned.

A Post-Login Action that adds the Google roles claim to the access token and enforces the intended AWS audience/role authorization rules.

Auth0 configuration

Auth0 is not provisioned by the Terraform file. Configure it separately before testing federation.

1. Configure the application

Create or use an Auth0 application for the client that obtains tokens. Configure an OAuth flow appropriate to your test client. If you use the device authorization flow, enable and configure that flow for the application and ensure the client can request the intended API audience.

Keep the application client ID available for Terraform configuration. A client ID is not a client secret, but tenant-specific identifiers should still be configured for the correct environment.

2. Configure the APIs and audiences

Create or use Auth0 APIs whose identifiers match the Terraform audience variables:

Terraform variable

Auth0 API identifier

auth0_api_audience

https://federation-lab.example.com

aws_readonly_audience

https://aws-readonly.example.com

aws_write_audience

https://aws-write.example.com

The identifiers are examples. Replace them consistently in Auth0 and Terraform if you choose different values.

3. Create and assign roles

Create the role values used by the lab and assign the appropriate role to each test user:

read-only

write-access

Use separate test identities where possible so that positive and negative authorization tests are easy to distinguish.

4. Configure the Post-Login Action

The Action should add the user's assigned roles to the Auth0 access token as a namespaced claim. The namespace expected by the Terraform configuration is:

https://identity.example.com/roles

The resulting access token should contain a roles array, for example:

{
  "https://identity.example.com/roles": ["read-only"]
}

The Action should also enforce the AWS audience-to-role policy before allowing a token to be issued for an AWS-specific audience. The AWS role trust policies in this Terraform configuration check the application/audience context; they do not directly inspect the namespaced roles claim. Therefore, the Auth0 Action's authorization decision is an important part of the AWS path.

Publish the Action and add it to the relevant Post-Login flow. Confirm that the claim is present in the access token, not only in the ID token.

5. Inspect a token before using it

Decode the JWT locally and verify the expected values:

iss: Auth0 tenant issuer matching the Terraform provider URL.

sub: the expected Auth0 user identifier.

aud: the requested API audience.

azp: the Auth0 application client ID, when present in the token.

https://identity.example.com/roles: the expected roles array for Google federation.

A decoded JWT is not proof that its signature is valid. AWS and Google validate the signature against the issuer's published keys during federation. Treat the complete token as a bearer credential: do not commit it, paste it into public issue trackers, or include it in screenshots or logs.

Terraform configuration

The Terraform file defines the following variables:

Variable

Purpose

Notes

auth0_domain

Auth0 tenant domain without https://

Must match the token's issuer host/domain

auth0_client_id

Auth0 application client ID

Used in the AWS OIDC provider client ID list and AWS trust conditions

auth0_api_audience

Google federation audience and legacy AWS role audience

Must match the Auth0 API identifier

aws_readonly_audience

AWS read-only audience

Must match the Auth0 API identifier requested for AWS read access

aws_write_audience

AWS write audience

Must match the Auth0 API identifier requested for AWS write access

auth0_user_id

Auth0 subject used by the legacy compatibility role

Not used by the two newer audience-specific AWS roles

gcp_project_id

Target Google Cloud project ID

Must identify the project where the pool and service accounts are created

aws_s3_lab_bucket_name

Dedicated S3 bucket name

S3 bucket names are globally unique; choose a name not already in use

Recommended local variable file

The current Terraform source contains environment-specific default values. For your own deployment, override them with a local terraform.tfvars file rather than editing values repeatedly in the main configuration.

Example terraform.tfvars:

auth0_domain         = "YOUR_TENANT.REGION.auth0.com"
auth0_client_id      = "YOUR_AUTH0_APPLICATION_CLIENT_ID"
auth0_api_audience   = "https://federation-lab.example.com"
aws_readonly_audience = "https://aws-readonly.example.com"
aws_write_audience   = "https://aws-write.example.com"
auth0_user_id        = "auth0|YOUR_TEST_USER_ID"
gcp_project_id       = "YOUR_GCP_PROJECT_ID"
aws_s3_lab_bucket_name = "your-unique-auth0-federation-lab-bucket"

Keep terraform.tfvars out of source control if it contains environment-specific identifiers or other private configuration. Never put Auth0 client secrets, AWS access keys, Google service-account keys, or Auth0 tokens in the Terraform file or Git repository.

The AWS provider is configured for us-east-1. The Google provider is configured for us-central1; the Workload Identity Pool itself is created in the global location as required by the resource configuration.

Deploy the infrastructure

Run these commands from the directory containing the Terraform configuration.

1. Authenticate to the cloud providers

Authenticate the AWS CLI to the intended AWS account using your normal approved method. For local Terraform use, Google Application Default Credentials can be configured with:

gcloud auth application-default login

Confirm that both identities point to the intended accounts/projects before applying changes.

2. Initialize Terraform

terraform init

This downloads the AWS, Google, and TLS providers specified in the Terraform configuration.

3. Format and validate

terraform fmt -recursive
terraform validate

4. Review the execution plan

terraform plan -out=tfplan

Review the plan carefully. Confirm the AWS account, Google project, Auth0 issuer, audiences, role names, and S3 bucket name before applying it.

5. Apply

terraform apply tfplan

Terraform provisions the OIDC provider, federated roles, S3 lab bucket and controls, Google Workload Identity Pool/provider, service accounts, and IAM bindings defined in the configuration.

6. Review outputs

terraform output

The current configuration outputs:

AWS OIDC provider ARN.

Legacy AWS federated role ARN.

Google Cloud project number.

Workload Identity Pool resource name.

Read-only Google service-account email.

Write-access Google service-account email.

Output note: The current file does not define output values for the two newer AWS audience-specific role ARNs or the S3 bucket name. Retrieve those from the AWS console/CLI or add explicit Terraform outputs if you want them available through terraform output.

Testing and verification

The aim of testing is to prove both that an authorized identity can obtain temporary credentials and that an identity with the wrong role or audience cannot cross an authorization boundary.

AWS: verify the OIDC provider and roles

Confirm that the OIDC provider exists:

aws iam list-open-id-connect-providers

Inspect the audience-specific roles:

aws iam get-role --role-name Auth0-DevOps-ReadOnly-Role
aws iam get-role --role-name Auth0-DevOps-Write-Role

Check the role's attached or inline permissions:

aws iam list-attached-role-policies --role-name Auth0-DevOps-ReadOnly-Role
aws iam list-role-policies --role-name Auth0-DevOps-Write-Role

AWS: assume the read-only role

Obtain an Auth0 access token for the AWS read-only audience using your configured Auth0 client flow. Store it temporarily in a protected local file or pass it securely to the CLI; do not put it in source control or shell history.

Then call AWS STS:

aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::<AWS_ACCOUNT_ID>:role/Auth0-DevOps-ReadOnly-Role" \
  --role-session-name "Auth0ReadOnlyTest" \
  --web-identity-token "$AUTH0_TOKEN" \
  --duration-seconds 3600

The command should return temporary access key, secret key, session token, and expiration fields if the token and trust policy are valid. Handle the returned credentials as secrets.

Use the temporary credentials in an isolated test shell or AWS profile, then verify the identity:

aws sts get-caller-identity

A read-only operation against an AWS resource should succeed when the role has the relevant read permission. A write operation should be denied by the read-only role's permissions.

AWS: assume the write role and test S3 scope

Obtain a separate Auth0 access token for the AWS write audience. Use the Auth0-DevOps-Write-Role ARN in the same STS operation.

After setting the returned temporary credentials in a protected test environment, test the dedicated bucket:

aws s3 ls "s3://<YOUR_LAB_BUCKET_NAME>"
echo "federation test" > federation-test.txt
aws s3 cp federation-test.txt "s3://<YOUR_LAB_BUCKET_NAME>/federation-test.txt"
aws s3 rm "s3://<YOUR_LAB_BUCKET_NAME>/federation-test.txt"

These operations exercise the permissions granted by the inline S3 policy. Attempting to write to an unrelated bucket should fail unless the assumed identity has additional permissions from another policy or permission boundary.

Google Cloud: inspect the provider and pool

Check that the pool and provider exist:

gcloud iam workload-identity-pools describe auth0-devops-pool \
  --location="global" \
  --project="YOUR_GCP_PROJECT_ID"

gcloud iam workload-identity-pools providers describe auth0-oidc-provider \
  --workload-identity-pool="auth0-devops-pool" \
  --location="global" \
  --project="YOUR_GCP_PROJECT_ID"

Review the provider's issuer, allowed audience, attribute mappings, and attribute condition. Confirm the service-account IAM bindings and the project-level Viewer binding are present.

Google Cloud: authenticate through Workload Identity Federation

The Terraform configuration creates the pool, provider, service accounts, and IAM bindings. It does not obtain an Auth0 token or generate an external-account credential configuration file.

For a manual test, use a fresh Auth0 access token for the GCP audience and save it to a protected local text file. For example, use auth0-readonly-token.txt for a read-only test. Do not commit this token file; add token files and generated credential configuration files to .gitignore.

Create an external-account credential configuration that points to the provider created by this project and the token file. The following PowerShell example uses the read-only service account:

$projectNumber = "YOUR_GCP_PROJECT_NUMBER"
$projectId = "YOUR_GCP_PROJECT_ID"
$serviceAccount = "YOUR_READ_ONLY_SERVICE_ACCOUNT_EMAIL"
$provider = "projects/$projectNumber/locations/global/workloadIdentityPools/auth0-devops-pool/providers/auth0-oidc-provider"

gcloud.cmd iam workload-identity-pools create-cred-config $provider `
  --service-account=$serviceAccount `
  --credential-source-file=".\auth0-readonly-token.txt" `
  --credential-source-type=text `
  --output-file="auth0-readonly-wif.json"

Then authenticate the Google Cloud CLI with the generated configuration:

gcloud.cmd auth login --cred-file=".\auth0-readonly-wif.json"
gcloud.cmd auth list

Test an operation that should be allowed by the read-only service account's project-level Viewer role:

gcloud.cmd projects describe $projectId

The auth0-readonly-token.txt file must contain the raw JWT text, not a JSON wrapper, for the --credential-source-type=text example above. The token must be valid when the credential is used. If it expires, obtain a fresh token and replace the file before repeating the test. The generated credential configuration contains no private key, but it still reveals environment and provider configuration; keep generated local files out of source control unless intentionally publishing sanitized examples.

To test the separate write-access service account, repeat the process with a fresh token whose roles claim has write-access as its first value, a separate token file, and the auth0-write-access service-account email. The federation/impersonation step should be allowed for that mapped principal. A Google Cloud resource write should still be denied because the current Terraform configuration grants that service account no resource-level or project-level permissions.

For application code, the same external-account configuration can be supplied to Google Auth Libraries. Set GOOGLE_APPLICATION_CREDENTIALS to the generated configuration path for libraries that use Application Default Credentials.

Suggested positive and negative test matrix

Test

Expected result

Reason

Valid Auth0 token for AWS read-only audience assumes AWS read-only role

Allow

Issuer/client/audience conditions match and the role grants read permissions

AWS read-only token attempts to assume AWS write role

Deny

AWS audience condition does not match the write role's expected audience

Valid AWS write token assumes AWS write role

Allow

Trust policy matches; the role receives the lab-bucket S3 policy

AWS write role writes to the dedicated lab bucket

Allow

The inline policy grants the listed S3 actions on that bucket and its objects

AWS write role writes to an unrelated bucket

Deny, absent other grants

The lab policy is scoped to the dedicated bucket

Google token has no roles claim

Deny

Provider attribute condition requires a non-empty roles claim

Google token's first role is not read-only or write-access

Deny

Provider attribute condition rejects unapproved role values

Google read-only principal impersonates auth0-devops-sa

Allow

Matching principalSet has roles/iam.workloadIdentityUser on the service account

Google read-only principal impersonates auth0-write-access

Deny

The write service account is bound to the write-access principal set, not read-only

Google write-access principal impersonates auth0-write-access

Allow

Matching principalSet has roles/iam.workloadIdentityUser on the service account

Google write service account attempts a resource write

Deny, absent other grants

No resource-level or project-level write role is granted to that service account here

Expected authorization failures

Federation failures are useful evidence that the trust boundary is working. Common causes include:

Symptom

Likely cause to check

AWS returns InvalidIdentityToken

Issuer URL, token signature, token expiry, provider registration, or token audience/client configuration

AWS returns an access-denied error when assuming a role

Role trust policy conditions do not match the token claims, including aud, azp, oaud, or sub where applicable

AWS read-only token cannot assume the write role

Expected behavior when the token's AWS audience does not match the write role's trust policy

Google reports an invalid or rejected external credential

Issuer URI, allowed audience, token expiry/signature, or provider attribute condition

Google rejects a token with a roles claim

Check the exact namespace, whether the claim is in the access token, whether the array is non-empty, and which role is at index 0

Google token exchange works but service-account impersonation is denied

Check the principalSet member string, project number, pool ID, mapped attribute name/value, and roles/iam.workloadIdentityUser binding

Google impersonation succeeds but a resource operation is denied

The service account may not have the required resource-level IAM role; this is expected for the write-access service account in the current configuration

When diagnosing a token, inspect claim names and values without sharing the token itself. Never add a production token to GitHub, logs, screenshots, or public JWT decoder websites.

Security considerations

This is a learning and portfolio lab. The following controls and limitations are important when adapting it for production.

What the configuration already demonstrates

Federated identity rather than requiring long-lived cloud access keys for end users.

A registered OIDC issuer in AWS IAM and a Google Workload Identity Federation provider.

Separate AWS audiences for read-only and write access paths.

A Google provider attribute condition that accepts only the role values defined in the configuration.

Attribute-based Google service-account impersonation bindings rather than granting the entire pool access.

A separate AWS write role with an S3 policy scoped to a dedicated lab bucket.

S3 public-access blocking and default SSE-S3 encryption.

Separate read-only and write-access service-account identities in Google Cloud.

Recommendations before production use

Remove environment-specific defaults. Replace the tenant, client, subject, project, and bucket defaults with environment-specific variables or a protected variable file. Do not publish personal user identifiers or account-specific resource names unnecessarily.

Review the legacy role. Auth0-DevOps-Federated-Role is a compatibility role with a specific Auth0 subject condition and the general federation audience. Retain it only while needed for migration/testing; remove it after the audience-specific roles have been validated.

Understand AWS role trust boundaries. The two newer AWS roles restrict the client and audience context, but their trust policies do not contain a sub condition or directly evaluate the namespaced Auth0 roles claim. The intended AWS role-to-user authorization therefore depends on the Auth0 Action correctly controlling which users can obtain tokens for each AWS audience. Add additional stable-identity or claim-based trust restrictions if the intended threat model requires them and the claims are supported by AWS IAM for the chosen IdP/token shape.

Keep permissions least-privileged. ReadOnlyAccess is a broad AWS-managed policy. For a production system, consider service-specific read policies. Keep write permissions scoped to the smallest practical resource and action set.

Grant Google write permissions deliberately. The Google write-access service account currently has no resource permissions. Add only the resource-level roles required for a defined task; do not grant project Editor or Owner merely to make a write test pass.

Review role claim semantics. The current Google mapping checks only the first role in the array. Ensure Auth0 emits a predictable ordering, or revise the mapping/condition and test it if multiple roles per user are required.

Protect the token acquisition path. Access tokens are bearer credentials. Store them in protected temporary locations, restrict file permissions, keep them out of shell history and logs, and delete them after testing.

Use strong Auth0 controls. Apply MFA, appropriate session controls, user lifecycle processes, and role assignment governance according to the sensitivity of the cloud resources.

Protect Terraform state. State can contain resource metadata and sensitive values from providers or future additions. Use an encrypted remote backend with restricted access, locking where supported, and appropriate retention for collaborative or production use.

Separate environments. Use separate Auth0 applications/audiences, pools/providers, roles, service accounts, and state for development, staging, and production rather than sharing one broad trust configuration.

Review auditability. Enable and retain AWS CloudTrail and Google Cloud audit logs according to the environment's monitoring and compliance requirements.

Validate changes before applying. Review Terraform plans and IAM trust/policy documents, particularly when adding new audiences, role bindings, or permissions.

Important distinction: authentication vs authorization

Auth0 authenticating a user proves an identity to the relying system. It does not automatically grant the user permission to perform cloud operations. Access is the combined result of:

Auth0 issuing an appropriately scoped token.

The cloud federation provider accepting the issuer, signature, audience, and required claims.

The AWS role trust policy or Google service-account impersonation binding authorizing the federated identity.

The resulting AWS role or Google service account having the required resource permissions.

Each layer should be independently reviewed and tested.

Current implementation boundaries

The following are deliberate boundaries of the Terraform configuration as it currently stands:

Auth0 users, roles, APIs, application settings, and Post-Login Actions are managed outside Terraform.

The Terraform code creates the AWS identity provider and IAM roles, but does not create an Auth0 token or a token acquisition script.

The Terraform code creates Google Workload Identity Federation resources, but does not generate an external-account credential file for each developer or client.

The legacy AWS role uses a fixed Auth0 subject variable. The two newer AWS roles are audience-specific and do not currently pin a subject.

The AWS write role is limited to the dedicated S3 lab bucket by its inline policy.

The Google write-access service account can be impersonated by the mapped write-access principal set, but has no resource permissions in this configuration.

Terraform outputs the legacy AWS role ARN, not the two newer AWS role ARNs or the S3 bucket name.

The S3 configuration blocks public access and enables SSE-S3 encryption; it does not configure bucket versioning, lifecycle rules, access logging, or replication.

These boundaries are useful to understand when reproducing the lab or extending it for a production design.

Cleanup

Destroy the resources created by this Terraform configuration when the lab is no longer needed:

terraform destroy

Review the destroy plan before confirming. The S3 bucket must be empty before Terraform can delete it because the resource is not configured with force_destroy = true. Remove any test objects first:

aws s3 rm "s3://<YOUR_LAB_BUCKET_NAME>" --recursive

Then run terraform destroy again. Do not remove shared IAM providers, roles, service accounts, or pools if other workloads depend on them; confirm ownership before cleanup.

References

AWS IAM: Create an OpenID Connect identity provider

AWS IAM: IAM and AWS STS condition context keys

AWS IAM: Request temporary security credentials using web identity

Google Cloud: Workload Identity Federation

Google Cloud: Configure Workload Identity Federation with other identity providers

Google Cloud CLI: Authenticate with a workload identity credential file

Google Cloud: Best practices for Workload Identity Federation

Auth0: Add roles and permissions to tokens using Actions

Auth0: Add custom claims to tokens
