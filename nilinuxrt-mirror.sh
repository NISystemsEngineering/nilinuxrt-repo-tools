#!/bin/bash

# ─── Configuration ────────────────────────────────────────────────────────────
FEED_VERSION="${1:-2026Q1}"   # e.g. 2026Q1, 2023Q2
FEED_ARCH="${2:-x64}"         # e.g. x64, arm
PARALLEL_DOWNLOADS=16          # concurrent downloads per feed
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

for FEED in "${FEEDS[@]}"; do
  SUBPATH=$(echo "$FEED" | sed 's|http://download.ni.com/||')
  DEST="$BASE_DIR/$SUBPATH"
  mkdir -p "$DEST"

  echo "==> Fetching index from $FEED"
  curl -sf "$FEED/Packages.gz" -o "$DEST/Packages.gz"

  if [ $? -ne 0 ]; then
    echo "    Packages.gz not found, trying Packages..."
    curl -sf "$FEED/Packages" -o "$DEST/Packages"
  else
    gunzip -c "$DEST/Packages.gz" > "$DEST/Packages"
  fi

  PKGFILE="$DEST/Packages"
  if [ ! -f "$PKGFILE" ]; then
    echo "    ERROR: Could not fetch package index for $FEED, skipping."
    continue
  fi

  curl -sf "$FEED/Packages.stamps" -o "$DEST/Packages.stamps"

  echo "==> Downloading packages from $FEED"
  grep "^Filename:" "$PKGFILE" | awk '{print $2}' | while read pkg; do
    PKGNAME=$(basename "$pkg")
    if [ ! -f "$DEST/$PKGNAME" ]; then
      echo "$FEED/$PKGNAME"
    else
      echo "    SKIP: $PKGNAME"
    fi
  done | grep "^http" | xargs -P "$PARALLEL_DOWNLOADS" -I {} sh -c '
    DEST="'"$DEST"'"
    PKGNAME=$(basename "{}")
    echo "    GET: $PKGNAME"
    curl -sf "{}" -o "$DEST/$PKGNAME"
  '

  echo "==> Done: $FEED"
  echo ""
done

echo "All feeds complete: ${FEED_VERSION}/${FEED_ARCH}"
