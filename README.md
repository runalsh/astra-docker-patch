# Astra Linux (se) Docker Patch Images

Automated build of Docker images for Astra Linux (ALSE 1.7 and 1.8) releases from official virtual machine images (`cloudinit` `.qcow2` format).

---

## ❓ Problem & Solution

Official Astra Linux base images are distributed primarily as VM disks. The `astra-docker-patch` project automates:
1. Scanning the Astra Linux Artifactory registry for available `cloudinit` VM images.
2. Filtering for base console images (`base`), excluding GUI versions (`gui`) and update releases (`uu`).
3. For each Astra Linux point version (e.g., `1.7.9`, `1.8.6`), picking **only the lowest minor mainline build** (e.g. `mg16.0.1` instead of `mg16.3.0`).
4. Converting the `.qcow2` image to a raw disk format, mounting the system partition, and importing the root filesystem directly into Docker.

---

## 🚀 Usage

### Scanning for releases

To query the Artifactory API, discover new releases, and populate `releases.txt`:
```bash
python3 discover_new_releases.py
```

### Building Docker images

To build a specific tag or all discovered tags locally:
```bash
# Build a specific release tag
./build.sh 1.8.6-mg16.4.0

# Build all versions present in releases.txt
./build.sh
```

---

## 🔧 Environment Variables

The `build.sh` script supports the following configuration options:

| Variable | Default | Description |
|---|---|---|
| `PUSH_TO_DOCKERHUB` | `false` | Automatically pushes built images to Docker Hub. |
| `PUSH_TO_GHCR` | `false` | Automatically pushes built images to GHCR. |
| `CLEANUP_DOCKER_IMAGES` | `false` | Deletes local Docker images after build and push. |
| `SKIP_EXISTS_CHECK` | `false` | Forces building and importing all tags regardless of remote registry status. |
| `ENABLE_TRIVY_SCAN` | `false` | Runs security scanning using Trivy (if present on the host). |
| `ALPINE_IMAGE` | `alpine:latest` | Alpine image used for raw disk mounting. |

---

## 🛡️ Security & Sandbox

The conversion (`qemu-img`), partition lookup, and mounting tasks are executed inside a privileged, sandboxed Alpine container. This isolates mount operations from the host filesystem and keeps the host system clean of additional dependencies.
