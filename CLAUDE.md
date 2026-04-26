# Foxi Linux — Claude Code context

## What this repo is

A minimal Linux distribution for AWS EC2. Alpine LTS kernel + Wolfi/Chainguard userspace, built with melange + apko, shipped as an EC2 AMI.

Build pipeline: `melange` builds `.apk` packages → `apko` assembles an OCI image → `scripts/build-ami.sh` converts it to a raw disk image and imports it as an AMI via `aws ec2 import-snapshot`.

## Key directories

- `packages/linux-lts/` — kernel melange package; `config/ec2.config` is the EC2-specific config fragment
- `packages/dhcpcd/` — custom DHCP client package (not in Wolfi)
- `packages/foxi/` — the foxi CLI apk package
- `images/ec2-base.yaml` — apko image definition (packages list, users, paths)
- `scripts/build-ami.sh` — disk image creation, rootfs customization, AMI import
- `tools/foxi/` — foxi CLI Python source
- `tools/tricks/` — bundled fallback tricks (YAML)

## The foxi CLI

`foxi` is an `apk` wrapper that runs post-install actions Wolfi intentionally omits (container-first design skips user creation, service registration, etc.). Post-install definitions are called **tricks** (always use this term, not "recipes" or "hooks").

Tricks live remotely at `github.com/iamfuzz/foxi-tricks`. Local cache at `/etc/foxi/tricks/`. Bundled fallback at `/usr/share/foxi/tricks/`.

### Critical: the `run` action must NOT use `capture_output=True`

`subprocess.run(..., capture_output=True)` holds pipes open while daemon child processes run, causing the trick to hang forever. The `run` handler in `tools/foxi/actions.py` intentionally omits output capture.

## Critical build-ami.sh details

**Home dir ownership:** apko extracts OCI layers with `--no-same-owner`, leaving `/home/ec2-user` owned by root. Must explicitly `chown 1000:1000` — otherwise sshd StrictModes silently rejects public key auth.

**Shadow file:** apko creates `/etc/passwd` entries but not `/etc/shadow`. OpenSSH requires a shadow entry. The build script adds one using `awk -v` (NOT sed with double-quotes — SHA-512 hashes contain `$6$` which shell expands destructively in double-quoted sed).

**GRUB console order:** `console=tty1 console=ttyS0,115200n8` — ttyS0 must be LAST so it is the primary output. If reversed, `aws ec2 get-console-output` shows nothing.

**sshd:** `UsePAM no` is required. Wolfi's openssh is compiled with PAM support; broken PAM config blocks public key auth even with a valid key.

**getty:** Use `/usr/bin/getty` (BusyBox), not `/sbin/agetty` (doesn't exist in Wolfi). `command_background=yes` requires a `pidfile` or OpenRC refuses to start it.

**reboot/halt/poweroff:** BusyBox in Wolfi omits these applets. Implemented via sysrq triggers written into `/sbin/reboot`, `/sbin/halt`, `/sbin/poweroff` during the build.

**import-snapshot:** Upload raw (uncompressed) image — AWS doesn't decompress gzip for RAW format. Use device paths in GRUB/fstab (not UUIDs) — import-snapshot regenerates ext4 UUIDs.

## Known non-fatal boot warnings

- Missing `loadkeys`/`kbd_mode` — OpenRC warns, continues
- BusyBox `sysctl` doesn't support `--system` — OpenRC warns, continues

## dhcpcd package gotcha

`make install` creates `/var/db/dhcpcd` with mode 0700. This blocks melange from writing SBOMs on CI (non-root). The melange.yaml pipeline explicitly removes the entire `/var` tree from destdir after install (all runtime state, nothing that should be packaged).

## Building locally

```bash
# Build a single package (non-root, bubblewrap runner)
melange build packages/<name>/melange.yaml \
  --arch x86_64 \
  --signing-key signing.rsa \
  --out-dir packages \
  --runner bubblewrap

# Build the OCI image
bash scripts/build-image.sh

# Build the AMI (requires AWS credentials)
sudo bash scripts/build-ami.sh
```

Do NOT run `scripts/build-packages.sh` just to test one package — it rebuilds the kernel (takes ~1 hour).
