#!/bin/bash

# ─── Configuration ────────────────────────────────────────────────────────────
FEED_VERSION="${1:-2026Q1}"   # e.g. 2026Q1, 2023Q2
FEED_ARCH="${2:-x64}"         # e.g. x64, arm
PKG_PATTERN="${3:-.*}"        # regex matched against package names, e.g. "^python3" or "gcc|make"
PARALLEL_DOWNLOADS=8          # concurrent downloads per feed
BASE_URL="http://download.ni.com/ni-linux-rt/feeds"
BASE_DIR="./ni-linux-rt-${FEED_VERSION}"
# ──────────────────────────────────────────────────────────────────────────────

FEED_ROOT="${BASE_URL}/${FEED_VERSION}/${FEED_ARCH}"

FEEDS=(
  "${FEED_ROOT}/extra/all"
  "${FEED_ROOT}/extra/${FEED_ARCH}"
  "${FEED_ROOT}/extra/core2-64"
  "${FEED_ROOT}/main/all"
  "${FEED_ROOT}/main/${FEED_ARCH}"
  "${FEED_ROOT}/main/core2-64"
)

# Temp dir for working files
TMPDIR=$(mktemp -d)
COMBINED_PKG="$TMPDIR/Packages.all"
trap "rm -rf $TMPDIR" EXIT

# ─── Phase 1: Fetch all indexes and combine into one package list ─────────────
echo "==> Fetching package indexes..."
for FEED in "${FEEDS[@]}"; do
  SUBPATH=$(echo "$FEED" | sed 's|http://download.ni.com/||')
  DEST="$BASE_DIR/$SUBPATH"
  mkdir -p "$DEST"

  curl -sf "$FEED/Packages.gz" -o "$DEST/Packages.gz"
  if [ $? -ne 0 ]; then
    curl -sf "$FEED/Packages" -o "$DEST/Packages"
  else
    gunzip -c "$DEST/Packages.gz" > "$DEST/Packages"
  fi

  curl -sf "$FEED/Packages.stamps" -o "$DEST/Packages.stamps" 2>/dev/null

  if [ -f "$DEST/Packages" ]; then
    # Tag each entry with its feed URL for later download
    sed "s|^Filename: |Filename: ${FEED}/|" "$DEST/Packages" >> "$COMBINED_PKG"
    echo "" >> "$COMBINED_PKG"
  else
    echo "    WARNING: No package index found for $FEED, skipping."
  fi
done

# ─── Phase 2: Build a dependency resolver from the combined index ─────────────
# Produces a lookup: package_name -> "filename|dep1 dep2 dep3"
resolve_deps() {
  python3 - "$COMBINED_PKG" "$PKG_PATTERN" <<'EOF'
import sys
import re

pkg_file = sys.argv[1]
pattern  = sys.argv[2]

# Parse the Packages file into a dict of package metadata
packages = {}
current = {}
with open(pkg_file) as f:
  for line in f:
    line = line.rstrip()
    if line == "":
      if "Package" in current:
        packages[current["Package"]] = current
      current = {}
    elif ": " in line:
      key, _, val = line.partition(": ")
      current[key] = val

# Flush last entry
if "Package" in current:
  packages[current["Package"]] = current

# Find all packages matching the pattern
matched = {name for name in packages if re.search(pattern, name)}

# Walk dependency tree
resolved = set()
queue = list(matched)
while queue:
  name = queue.pop()
  if name in resolved or name not in packages:
    continue
  resolved.add(name)
  deps_raw = packages[name].get("Depends", "")
  # Dependencies are comma-separated, may have version constraints e.g. "libfoo (>= 1.0)"
  for dep in deps_raw.split(","):
    dep_name = re.sub(r"\s*\(.*?\)", "", dep).strip()
    if dep_name and dep_name not in resolved:
      queue.append(dep_name)

# Output: one "filename|pkgname" per resolved package
for name in resolved:
  pkg = packages.get(name)
  if pkg and "Filename" in pkg:
    print(f"{pkg['Filename']}|{name}")
  else:
    print(f"MISSING|{name}", file=sys.stderr)
EOF
}

# ─── Phase 3: Download resolved packages ──────────────────────────────────────
echo ""
echo "==> Resolving dependencies for pattern: '$PKG_PATTERN'"
RESOLVED=$(resolve_deps)

if [ -z "$RESOLVED" ]; then
  echo "    ERROR: No packages matched pattern '$PKG_PATTERN'. Exiting."
  exit 1
fi

echo "    Packages to download:"
echo "$RESOLVED" | awk -F'|' '{print "    - "$2}' | sort

echo ""
echo "==> Downloading resolved packages..."

# Build a dest-lookup per URL and download in parallel
echo "$RESOLVED" | grep -v "^MISSING" | while IFS='|' read url pkgname; do
  # Reconstruct the local dest path from the URL
  SUBPATH=$(echo "$url" | sed 's|http://download.ni.com/||' | xargs dirname)
  DEST="$BASE_DIR/$SUBPATH"
  mkdir -p "$DEST"
  PKGNAME=$(basename "$url")
  if [ -f "$DEST/$PKGNAME" ]; then
    echo "SKIP $DEST/$PKGNAME"
  else
    echo "$url $DEST/$PKGNAME"
  fi
done | grep -v "^SKIP" | xargs -P "$PARALLEL_DOWNLOADS" -I {} sh -c '
  URL=$(echo "{}" | awk "{print \$1}")
  DEST=$(echo "{}" | awk "{print \$2}")
  echo "    GET: $(basename $DEST)"
  curl -sf "$URL" -o "$DEST"
'

echo ""
echo "==> Done. Matched pattern: '$PKG_PATTERN'"
echo "    Packages written to: $BASE_DIR"
