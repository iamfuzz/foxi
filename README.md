# Foxi Linux

A minimal Linux distribution for AWS EC2 built from Alpine Linux kernel sources using the Wolfi/Chainguard toolchain.

**Why it exists:** EC2 instances that can consume [Chainguard packages](https://www.chainguard.dev/chainguard-images) directly from `apk`, on a kernel with Alpine's security hardening, with a fully reproducible build pipeline.

## How it's built

```
Alpine kernel sources (6.6.x LTS)
        │
        ▼
   melange build          ← produces signed .apk packages
        │
        ▼
    apko build            ← assembles OCI image from packages + Chainguard repos
        │
        ▼
  raw disk image          ← GRUB installed, partitioned for EC2 (GPT/EFI)
        │
        ▼
  EC2 AMI (us-east-1)    ← imported via VM Import, registered with ENA + IMDSv2
```

Kernel updates are checked daily. When a new 6.6.x release appears on kernel.org a pull request is opened automatically with the version and SHA256 updated. Merging the PR triggers a full rebuild and publishes a new AMI.

## Using the AMI

### Launch an instance

```bash
# Get the latest AMI ID
AMI_ID=$(aws ec2 describe-images \
  --region us-east-1 \
  --owners 647081594955 \
  --filters "Name=tag:ManagedBy,Values=foxi" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

aws ec2 run-instances \
  --region us-east-1 \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name YOUR_KEY_PAIR \
  --metadata-options HttpTokens=required \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=foxi-test}]'
```

### SSH in

```bash
ssh -i YOUR_KEY.pem ec2-user@<instance-public-ip>
```

The default user is `ec2-user`. Root login and password authentication are disabled.

### Install Chainguard packages

The instance ships with `apk` pointed at the Wolfi repository:

```bash
# Search for a package
apk search <package>

# Install a package
sudo apk add <package>

# Update all packages
sudo apk upgrade
```

## Repository layout

```
├── packages/
│   └── linux-lts/
│       ├── melange.yaml        # Kernel package definition
│       └── config/
│           └── ec2.config      # EC2-specific kernel config fragment
├── images/
│   └── ec2-base.yaml           # apko image definition
├── iam/                        # IAM policy documents (used by scripts/setup-aws.sh)
├── scripts/
│   ├── build-packages.sh       # Build APKs with melange
│   ├── build-image.sh          # Build OCI image with apko
│   ├── build-ami.sh            # Convert image to EC2 AMI
│   ├── check-updates.sh        # Poll kernel.org for new LTS versions
│   └── setup-aws.sh            # One-time AWS infrastructure setup
└── .github/workflows/
    ├── build.yml               # Build pipeline (triggered on push to main)
    └── update-check.yml        # Daily kernel update check
```

## Triggering a manual rebuild

Go to **Actions → Build Foxi Linux → Run workflow**. Check "Create and register AMI" to also publish a new AMI, otherwise it stops after building the image artifact.

## Setting up from scratch

### Prerequisites

- AWS account with permissions to create IAM roles, S3 buckets, and EC2 resources
- GitHub repository with Actions enabled

### 1. Generate a signing key

```bash
melange keygen signing.rsa
# signing.rsa.pub is committed to the repo
# signing.rsa goes into GitHub as a repository secret
```

### 2. Run the AWS setup script

```bash
./scripts/setup-aws.sh \
  --github-repo YOUR_ORG/YOUR_REPO \
  --bucket YOUR_BUCKET_NAME \
  --region us-east-1
```

This creates the S3 bucket, GitHub OIDC provider, `foxi-github-actions` IAM role, and the `vmimport` service role required by EC2 VM Import.

### 3. Set GitHub repository secrets and variables

| Type | Name | Value |
|------|------|-------|
| Secret | `MELANGE_SIGNING_KEY` | Full contents of `signing.rsa` |
| Secret | `AWS_ROLE_ARN` | Output from setup script |
| Variable | `AWS_REGION` | e.g. `us-east-1` |
| Variable | `S3_BUCKET` | Bucket name from setup script |

### 4. Push to main

The build workflow triggers automatically.

## Kernel configuration

The kernel is built from the upstream 6.6.x LTS tarball with:

- **Alpine's config** as a baseline (security hardening, broad hardware support)
- **EC2-specific additions** from `packages/linux-lts/config/ec2.config`:
  - ENA driver (required on all Nitro instances)
  - NVMe storage (Nitro instance store and EBS)
  - Xen drivers (older instance families)
  - Virtio (network and block)
  - EFI boot + serial console at `ttyS0:115200`
  - IMDSv2-compatible networking

## Security notes

- IMDSv2 is enforced on launch (`HttpTokens=required`)
- Root login over SSH is disabled
- Password authentication is disabled
- The AMI is registered as private by default
- Signing keys should be rotated periodically; regenerate with `melange keygen` and update the `MELANGE_SIGNING_KEY` secret
