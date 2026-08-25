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

## ✂️ What is Stripped from the Rootfs (Size Optimization)

Official Astra Linux SE `cloudinit` VM QCOW2 images contain full Linux kernel modules, kernel headers, GRUB bootloaders, and development packages meant for virtual machines.

The build script strips non-container bloat, reducing the uncompressed Docker image from **~1.6 GB** down to **~640 MB** (saving over **960 MB** / **>60%** per image):

| Component / Path | What it is | Why it is safe to remove in Docker | Disk Space Saved |
|---|---|---|---|
| **Linux Kernel & Modules** (`/usr/lib/modules`, `/lib/modules`, `/boot/vmlinuz*`, `/boot/initrd*`) | Linux 6.1 kernel binaries and device drivers | Containers share the host Linux kernel; internal kernel files are never loaded. | **~655 MB** |
| **Kernel Headers** (`/usr/src/linux-headers*`) | Linux kernel C header files | Not required for runtime container execution. | **~75 MB** |
| **GRUB Bootloader** (`/usr/lib/grub*`, `/boot/grub*`, `/etc/grub.d`) | GRUB2 BIOS/EFI bootloader stages | Containers start directly via `runc` without BIOS/EFI boot. | **~30 MB** |
| **Non-RU/EN Locales** (`/usr/share/locale/*`) | System translation catalogs for foreign languages | Containers preserve only `ru_RU.UTF-8`, `en_US.UTF-8`, and `POSIX`. | **~60 MB** |
| **APT Index Lists & Cache** (`/var/lib/apt/lists/*`, `/var/cache/apt/*`) | Downloaded package index caches | Refreshed automatically during `apt-get update`. | **~30 MB** |
| **Documentation & Manuals** (`/usr/share/{doc,man,info}`) | Changelogs, copyright notices, and man pages | Not used by headless automated daemons. | **~60 MB** |
| **Temporary Files & Logs** (`/tmp/*`, `/var/log/*`, `/var/tmp/*`) | VM template bootstrap install logs | Re-generated on demand during runtime. | **~15 MB** |
| **Total Savings** | | | **~960+ MB (>60% reduction)** |

---

## 🔧 Environment Variables

The `build.sh` script supports the following configuration options:

| Variable | Default | Description |
|---|---|---|
| `PUSH_TO_DOCKERHUB` | `false` | Automatically pushes built images to Docker Hub. |
| `PUSH_TO_GHCR` | `false` | Automatically pushes built images to GHCR. |
| `CLEANUP_DOCKER_IMAGES` | `false` | Deletes local Docker images after build and push. |
| `SKIP_EXISTS_CHECK` | `false` | Forces building and importing all tags regardless of remote registry status. |
| `ALPINE_IMAGE` | `alpine:latest` | Alpine image used for raw disk mounting. |

---

## 🛡️ Security & Sandbox

The conversion (`qemu-img`), partition lookup, and mounting tasks are executed inside a privileged, sandboxed Alpine container. This isolates mount operations from the host filesystem and keeps the host system clean of additional dependencies.
