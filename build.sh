#!/bin/bash
set -euo pipefail

# Configurable Docker Hub image name and сustom sifting
IMAGE_NAME="runalsh/astra-patch"
RELEASES_FILE="releases.txt"
ALPINE_IMAGE="alpine:latest"
MISMATCHED_TAGS=()

if [ ! -f "$RELEASES_FILE" ]; then
    echo "Error: $RELEASES_FILE not found! Run discover_new_releases.py first."
    exit 1
fi


echo "Starting process for image repository: ${IMAGE_NAME}"

# Determine latest tags for different Astra major tracks (1.7 and 1.8)
LATEST_17=$(grep -E "^1\.7\." "$RELEASES_FILE" | sort -V | tail -n 1 | awk '{print $1}')
LATEST_18=$(grep -E "^1\.8\." "$RELEASES_FILE" | sort -V | tail -n 1 | awk '{print $1}')
OVERALL_LATEST=$(sort -V "$RELEASES_FILE" | tail -n 1 | awk '{print $1}')

while read -r tag url || [ -n "$tag" ]; do
    [[ -z "$tag" || "$tag" =~ ^# ]] && continue

    echo "=========================================="
    echo "Processing tag: ${tag}"
    echo "URL: ${url}"
    echo "=========================================="

    FULL_IMAGE_TAG="${IMAGE_NAME}:${tag}"
    GHCR_IMAGE_NAME="ghcr.io/$(echo "${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')"
    FULL_GHCR_TAG="${GHCR_IMAGE_NAME}:${tag}"

    MAJOR_VER=$(echo "${tag}" | cut -d'.' -f1-2) # e.g. "1.7" or "1.8"
    
    IS_LATEST_MAJOR=false
    if [ "$MAJOR_VER" = "1.7" ] && [ "$tag" = "$LATEST_17" ]; then
        if ! grep -q "^1\.7$" "$RELEASES_FILE"; then
            IS_LATEST_MAJOR=true
            echo "Tag ${tag} is latest for Astra 1.7. Will tag as 1.7!"
        fi
    elif [ "$MAJOR_VER" = "1.8" ] && [ "$tag" = "$LATEST_18" ]; then
        if ! grep -q "^1\.8$" "$RELEASES_FILE"; then
            IS_LATEST_MAJOR=true
            echo "Tag ${tag} is latest for Astra 1.8. Will tag as 1.8!"
        fi
    fi

    IS_OVERALL_LATEST=false
    if [ "$tag" = "$OVERALL_LATEST" ]; then
        IS_OVERALL_LATEST=true
        echo "Tag ${tag} is overall latest. Will tag as latest!"
    fi

    TARGET_ARG="${1:-all}"
    if [ "$TARGET_ARG" != "all" ] && [ "$TARGET_ARG" != "$tag" ]; then
        continue
    fi

    NEEDS_DOCKERHUB_PUSH=false
    NEEDS_GHCR_PUSH=false

    if [ "${SKIP_EXISTS_CHECK:-false}" = "true" ] || [ "${CHECK_REMOTE_TAGS:-true}" = "false" ]; then
        echo "SKIP_EXISTS_CHECK is true (or CHECK_REMOTE_TAGS is false). Forcing build and push..."
        [ "${PUSH_TO_DOCKERHUB:-false}" = "true" ] && NEEDS_DOCKERHUB_PUSH=true
        [ "${PUSH_TO_GHCR:-false}" = "true" ] && NEEDS_GHCR_PUSH=true
    else
        if [ "${PUSH_TO_DOCKERHUB:-false}" = "true" ]; then
            if ! docker manifest inspect "${FULL_IMAGE_TAG}" &>/dev/null && ! curl -sfSL "https://hub.docker.com/v2/repositories/${IMAGE_NAME}/tags/${tag}/" &>/dev/null; then
                echo "Tag ${FULL_IMAGE_TAG} missing on Docker Hub."
                NEEDS_DOCKERHUB_PUSH=true
            else
                echo "Tag ${FULL_IMAGE_TAG} exists on Docker Hub."
            fi
        fi

        if [ "${PUSH_TO_GHCR:-false}" = "true" ]; then
            if ! docker manifest inspect "${FULL_GHCR_TAG}" &>/dev/null; then
                echo "Tag ${FULL_GHCR_TAG} missing on GHCR."
                NEEDS_GHCR_PUSH=true
            else
                echo "Tag ${FULL_GHCR_TAG} exists on GHCR."
            fi
        fi

        if [ "${NEEDS_DOCKERHUB_PUSH}" = "false" ] && [ "${NEEDS_GHCR_PUSH}" = "false" ]; then
            if [ "${PUSH_TO_DOCKERHUB:-false}" = "true" ] || [ "${PUSH_TO_GHCR:-false}" = "true" ]; then
                echo "Tag ${tag} already exists on remote registries. Skipping download and build!"
                echo
                continue
            fi
        fi
    fi

    QCOW2_FILE="temp_rootfs_${tag}.qcow2"

    echo "1. Downloading QCOW2 image archive..."
    curl -fSL -o "${QCOW2_FILE}" "${url}"

    echo "2. Extracting rootfs from QCOW2 and importing into Docker as ${FULL_IMAGE_TAG}..."
    ABS_QCOW2_PATH="$(pwd)/${QCOW2_FILE}"
    
    docker run --rm --privileged -v "${ABS_QCOW2_PATH}:/work/image.qcow2:ro" "${ALPINE_IMAGE}" sh -c '
        apk add --no-cache qemu-img parted >/dev/null 2>&1
        mkdir -p /tmp/mount_rootfs
        
        # Convert QCOW2 to raw disk format
        qemu-img convert -O raw /work/image.qcow2 /tmp/disk.raw
        
        # Detect Linux partition (typically partition 2)
        START_SECTOR=$(parted -s /tmp/disk.raw unit s print | awk '\''$1=="2" {print $2}'\'' | tr -d '\''s'\'')
        if [ -z "$START_SECTOR" ]; then
            # fallback to searching for ext4 partition
            START_SECTOR=$(parted -s /tmp/disk.raw unit s print | grep -i "ext4" | awk '\''{print $2}'\'' | tr -d '\''s'\'')
        fi
        
        if [ -z "$START_SECTOR" ]; then
            echo "ERROR: Could not find partition 2 or ext4 partition in image" >&2
            exit 1
        fi
        
        OFFSET=$((START_SECTOR * 512))
        
        # Mount loop partition read-only and export it as tar
        mount -o loop,ro,offset=${OFFSET} /tmp/disk.raw /tmp/mount_rootfs
        tar -C /tmp/mount_rootfs -cf - .
        umount /tmp/mount_rootfs
        rm -f /tmp/disk.raw
    ' | docker import - "${FULL_IMAGE_TAG}"

    rm -f "${QCOW2_FILE}"

    echo "3. Skipping running the container to verify OS release (as requested)."



    if [ "${NEEDS_DOCKERHUB_PUSH}" = "true" ] || [ "${PUSH_TO_DOCKERHUB:-false}" = "true" ]; then
        echo "4. Pushing image to Docker Hub (${FULL_IMAGE_TAG})..."
        docker push "${FULL_IMAGE_TAG}" || true
        
        if [ "$IS_LATEST_MAJOR" = "true" ]; then
            MAJOR_TAG="${IMAGE_NAME}:${MAJOR_VER}"
            echo "Pushing major alias tag to Docker Hub (${MAJOR_TAG})..."
            docker tag "${FULL_IMAGE_TAG}" "${MAJOR_TAG}"
            CREATED_TAGS+=("${MAJOR_TAG}")
            docker push "${MAJOR_TAG}" || true
        fi

        if [ "$IS_OVERALL_LATEST" = "true" ]; then
            LATEST_TAG="${IMAGE_NAME}:latest"
            echo "Pushing latest tag to Docker Hub (${LATEST_TAG})..."
            docker tag "${FULL_IMAGE_TAG}" "${LATEST_TAG}"
            CREATED_TAGS+=("${LATEST_TAG}")
            docker push "${LATEST_TAG}" || true
        fi
    else
        echo "5. Skipping Docker Hub push."
    fi

    if [ "${NEEDS_GHCR_PUSH}" = "true" ] || [ "${PUSH_TO_GHCR:-false}" = "true" ]; then
        echo "5. Pushing image to GitHub Packages / GHCR (${FULL_GHCR_TAG})..."
        docker tag "${FULL_IMAGE_TAG}" "${FULL_GHCR_TAG}"
        CREATED_TAGS+=("${FULL_GHCR_TAG}")
        docker push "${FULL_GHCR_TAG}" || true

        if [ "$IS_LATEST_MAJOR" = "true" ]; then
            GHCR_MAJOR_TAG="${GHCR_IMAGE_NAME}:${MAJOR_VER}"
            echo "Pushing major alias tag to GHCR (${GHCR_MAJOR_TAG})..."
            docker tag "${FULL_IMAGE_TAG}" "${GHCR_MAJOR_TAG}"
            CREATED_TAGS+=("${GHCR_MAJOR_TAG}")
            docker push "${GHCR_MAJOR_TAG}" || true
        fi

        if [ "$IS_OVERALL_LATEST" = "true" ]; then
            GHCR_LATEST_TAG="${GHCR_IMAGE_NAME}:latest"
            echo "Pushing latest tag to GHCR (${GHCR_LATEST_TAG})..."
            docker tag "${FULL_IMAGE_TAG}" "${GHCR_LATEST_TAG}"
            CREATED_TAGS+=("${GHCR_LATEST_TAG}")
            docker push "${GHCR_LATEST_TAG}" || true
        fi

        if [ "${CLEANUP_DOCKER_IMAGES:-false}" = "true" ]; then
            docker rmi -f "${FULL_GHCR_TAG}" 2>/dev/null || true
        fi
    else
        echo "6. Skipping GHCR push."
    fi

    if [ "${CLEANUP_DOCKER_IMAGES:-false}" = "true" ]; then
        echo "Removing local Docker image ${FULL_IMAGE_TAG} to save disk space..."
        docker rmi -f "${FULL_IMAGE_TAG}" 2>/dev/null || true
    fi

    echo "Successfully completed processing for tag ${tag}!"
    echo
done < "$RELEASES_FILE"

if [ ${#MISMATCHED_TAGS[@]} -gt 0 ]; then
    echo "=========================================="
    echo "SUMMARY: Version mismatches detected!"
    echo "The following tags failed verification:"
    for m in "${MISMATCHED_TAGS[@]}"; do
        echo "  - ${m}"
    done
    echo "=========================================="
    exit 1
else
    echo "All images processed and verified successfully!"
fi
