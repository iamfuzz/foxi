# Foxi Linux

A minimal Linux distribution for AWS EC2 built from Alpine Linux kernel sources using the Wolfi/Chainguard toolchain.

**Why it exists:** EC2 instances that can consume [Chainguard packages](https://www.chainguard.dev/os-packages) directly from `apk`, on a kernel with Alpine's security hardening, with a fully reproducible build pipeline.

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

### Find the latest AMI

The latest AMI ID is published with each build on the [Releases page](https://github.com/iamfuzz/foxi/releases). Grab the AMI ID from there, then launch with:

### Launch an instance

```bash
aws ec2 run-instances \
  --region us-east-1 \
  --image-id ami-XXXXXXXXXXXXXXXXX \
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

## Foxi Tricks

Wolfi packages are designed for containers and intentionally skip post-install scripts (user creation, directory setup, service registration). **Foxi Tricks** fills that gap — a lightweight `apk` wrapper that runs typed post-install actions after a package is installed.

### Install a package with its trick

```bash
sudo foxi add nginx
```

This runs `apk add nginx` and then executes nginx's trick: creating the `nginx` user and group, setting up log and data directories with correct ownership, fixing the pid path, enabling the service at boot, and starting it immediately.

### Available tricks

| Package | What it does |
|---------|-------------|
| `nginx` | User/group, log dirs, pid fix, autostart |

More tricks are coming. Contributions welcome at [foxi-tricks](https://github.com/iamfuzz/foxi-tricks).

### Manage tricks

```bash
# Refresh the remote trick index
sudo foxi tricks update

# List available tricks and which are cached locally
sudo foxi tricks list

# Pre-fetch a trick without installing the package
sudo foxi tricks fetch nginx
```

### Writing your own trick

Each trick is a YAML file with typed actions (`add_user`, `add_group`, `mkdir`, `chown`, `chmod`, `symlink`, `write_file`, `run`). The fastest way to write a new trick is to look up the equivalent Alpine package in [aports](https://gitlab.alpinelinux.org/alpine/aports) and port its `.post-install` script into the typed action format.

For example, Alpine's `nginx.post-install` creates the nginx user and directories — the same steps become `add_group`, `add_user`, and `mkdir` actions in a Foxi trick. The typed format is safer than raw shell: each action is validated before execution and the common operations have idempotency built in (e.g. `add_user` is a no-op if the user already exists).

Submit new tricks as pull requests to [iamfuzz/foxi-tricks](https://github.com/iamfuzz/foxi-tricks).

## Repository layout

```
├── tools/
│   ├── foxi/                   # foxi CLI source (Python)
│   ├── tricks/                 # Bundled fallback tricks
│   └── setup.py
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

## License

The build system (scripts, package specs, image configs) is licensed under [Apache-2.0](LICENSE).

The Linux kernel included in the image is licensed under GPL-2.0-only. Source is available at [kernel.org](https://cdn.kernel.org/pub/linux/kernel/v6.x/).

## Security notes

- IMDSv2 is enforced on launch (`HttpTokens=required`)
- Root login over SSH is disabled
- Password authentication is disabled
- AMIs are public by default — the latest AMI ID is published with each [GitHub Release](https://github.com/iamfuzz/foxi/releases)
- Signing keys should be rotated periodically; regenerate with `melange keygen` and update the `MELANGE_SIGNING_KEY` secret
