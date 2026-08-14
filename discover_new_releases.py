#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request

API_URL = "https://registry.astralinux.ru/artifactory/api/storage/mg-generic/alse/cloudinit"
BASE_DOWNLOAD_URL = "https://registry.astralinux.ru/artifactory/mg-generic/alse/cloudinit"
RELEASES_FILE = "releases.txt"

def load_existing_releases(releases_path):
    existing = set()
    if not os.path.exists(releases_path):
        return existing
    with open(releases_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split()
                if parts:
                    existing.add(parts[0])
    return existing

def main():
    existing_tags = load_existing_releases(RELEASES_FILE)
    print(f"Loaded {len(existing_tags)} existing tags from {RELEASES_FILE}")

    req = urllib.request.Request(API_URL, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"Failed to fetch Artifactory API: {e}", file=sys.stderr)
        sys.exit(1)

    children = data.get("children", [])
    print(f"Found {len(children)} total items in Artifactory directory")

    discoveries = []
    # Pattern to extract astra_version and mg_version
    # e.g., /alse-1.7.10-base-cloudinit-mg16.5.0-amd64.qcow2 -> group 1: 1.7.10, group 2: mg16.5.0
    pattern = re.compile(r"^/alse-([0-9\.]+)-base-cloudinit-(mg[0-9\.]+|latest)-amd64\.qcow2$")

    for child in children:
        uri = child.get("uri", "")
        # Apply filters: base, no uu, no gui, ends with qcow2
        if "base" not in uri or "uu" in uri or "gui" in uri or not uri.endswith(".qcow2"):
            continue

        m = pattern.match(uri)
        if not m:
            continue

        astra_ver = m.group(1)
        mg_ver = m.group(2)
        tag = astra_ver

        # Extract filename (removing leading slash)
        filename = uri.lstrip("/")
        download_url = f"{BASE_DOWNLOAD_URL}/{filename}"

        discoveries.append({
            "tag": tag,
            "url": download_url,
            "astra_ver": astra_ver,
            "mg_ver": mg_ver
        })

    # Sort key for version comparisons
    def version_key(item):
        tokens = re.split(r'([^0-9]+)', item['tag'])
        key = []
        for tok in tokens:
            if not tok:
                continue
            if tok.isdigit():
                key.append((0, int(tok)))
            else:
                key.append((1, tok))
        return key

    # Group discoveries by astra_ver and keep only the lowest mg_ver
    grouped = {}
    for item in discoveries:
        aver = item["astra_ver"]
        if aver not in grouped:
            grouped[aver] = []
        grouped[aver].append(item)

    final_releases = []
    for aver, items in grouped.items():
        # Sort items of this astra_ver by version_key
        items.sort(key=version_key)
        # Keep the lowest one (index 0)
        final_releases.append(items[0])

    # Sort final releases globally by tag
    final_releases.sort(key=version_key)

    print(f"\nWriting {len(final_releases)} unique releases (lowest mg_ver per astra_ver):")
    for item in final_releases:
        print(f" - {item['tag']}: {item['url']}")

    with open(RELEASES_FILE, "w", encoding="utf-8") as f:
        for item in final_releases:
            f.write(f"{item['tag']} {item['url']}\n")

    print(f"Overwrote {RELEASES_FILE}")

    new_discoveries = [item for item in final_releases if item["tag"] not in existing_tags]
    if new_discoveries:
        first_new = new_discoveries[0]
        print(f"Discovered {len(new_discoveries)} new releases.")
        if "GITHUB_ENV" in os.environ:
            with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as f:
                f.write("NEW_RELEASE_FOUND=true\n")
                f.write(f"NEW_TAG={first_new['tag']}\n")
                f.write(f"NEW_URL={first_new['url']}\n")
    else:
        print("No new releases discovered.")
        if "GITHUB_ENV" in os.environ:
            with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as f:
                f.write("NEW_RELEASE_FOUND=false\n")

if __name__ == "__main__":
    main()
