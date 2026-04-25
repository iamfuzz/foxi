#!/usr/bin/env bash
# One-time AWS setup for Foxi Linux CI.
# Run this from a machine with AWS CLI configured as an admin.
#
# Usage:
#   ./scripts/setup-aws.sh \
#     --github-repo  YOUR_ORG/YOUR_REPO \
#     --bucket       foxi-images-<something-unique> \
#     --region       us-east-1
set -euo pipefail

IAM_DIR="$(cd "$(dirname "$0")/../iam" && pwd)"

GITHUB_REPO=""
BUCKET=""
REGION="us-east-1"

usage() {
  echo "Usage: $0 --github-repo ORG/REPO --bucket BUCKET_NAME [--region REGION]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --bucket)      BUCKET="$2";      shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$GITHUB_REPO" && -n "$BUCKET" ]] || usage

GITHUB_ORG="${GITHUB_REPO%%/*}"
GITHUB_REPONAME="${GITHUB_REPO##*/}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS account: $ACCOUNT_ID"
echo "Region:      $REGION"
echo "Bucket:      $BUCKET"
echo "GitHub repo: $GITHUB_REPO"
echo ""

# ── 1. S3 bucket ─────────────────────────────────────────────────────────────
echo "==> Creating S3 bucket: $BUCKET"
if [[ "$REGION" == "us-east-1" ]]; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" 2>/dev/null || echo "    (bucket may already exist)"
else
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null \
    || echo "    (bucket may already exist)"
fi

# Block all public access — images should never be public
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Lifecycle rule: expire raw images after 30 days (the AMI snapshot is the durable artifact)
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-raw-images",
      "Status": "Enabled",
      "Filter": {"Prefix": "foxi/images/"},
      "Expiration": {"Days": 30}
    }]
  }'

echo "    Done."

# ── 2. GitHub OIDC identity provider ─────────────────────────────────────────
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "==> Ensuring GitHub OIDC provider exists"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" &>/dev/null; then
  echo "    Already exists."
else
  # Fetch GitHub's OIDC thumbprint
  THUMBPRINT=$(echo | openssl s_client -connect token.actions.githubusercontent.com:443 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
    | sed 's/SHA1 Fingerprint=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')

  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "$THUMBPRINT"
  echo "    Created."
fi

# ── 3. GitHub Actions IAM role ────────────────────────────────────────────────
ROLE_NAME="foxi-github-actions"

echo "==> Creating GitHub Actions IAM role: $ROLE_NAME"

# Substitute account ID and repo into the trust policy
TRUST_POLICY=$(sed \
  -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
  -e "s/GITHUB_ORG/${GITHUB_ORG}/g" \
  -e "s/GITHUB_REPO/${GITHUB_REPONAME}/g" \
  "$IAM_DIR/github-actions-trust-policy.json")

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "    Role already exists, updating trust policy."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Used by GitHub Actions to build and publish Foxi Linux AMIs"
fi

# Attach the permissions policy
INLINE_POLICY=$(sed "s/BUCKET_NAME/${BUCKET}/g" "$IAM_DIR/github-actions-policy.json")
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "foxi-build-permissions" \
  --policy-document "$INLINE_POLICY"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "    Role ARN: $ROLE_ARN"

# ── 4. vmimport service role ──────────────────────────────────────────────────
# AWS's VM Import service requires a role named exactly "vmimport".
# Without it, ec2:ImportSnapshot fails with an opaque access denied error.
VMIMPORT_ROLE="vmimport"

echo "==> Creating vmimport service role"
if aws iam get-role --role-name "$VMIMPORT_ROLE" &>/dev/null; then
  echo "    Role already exists."
else
  aws iam create-role \
    --role-name "$VMIMPORT_ROLE" \
    --assume-role-policy-document "file://${IAM_DIR}/vmimport-trust-policy.json" \
    --description "Allows AWS VM Import/Export to access S3 and EC2 on your behalf"
fi

VMIMPORT_POLICY=$(sed "s/BUCKET_NAME/${BUCKET}/g" "$IAM_DIR/vmimport-policy.json")
aws iam put-role-policy \
  --role-name "$VMIMPORT_ROLE" \
  --policy-name "foxi-vmimport-permissions" \
  --policy-document "$VMIMPORT_POLICY"

echo "    Done."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo " Setup complete. Add these to your GitHub repo:"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Settings → Secrets and variables → Actions"
echo ""
echo " SECRETS:"
echo "   AWS_ROLE_ARN  =  ${ROLE_ARN}"
echo ""
echo " VARIABLES:"
echo "   AWS_REGION    =  ${REGION}"
echo "   S3_BUCKET     =  ${BUCKET}"
echo ""
echo " Also confirm MELANGE_SIGNING_KEY secret is already set."
echo "════════════════════════════════════════════════════════════"
