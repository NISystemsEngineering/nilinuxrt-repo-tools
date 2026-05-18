#!/bin/bash

# ─── Configuration ────────────────────────────────────────────────────────────
FEED_VERSION="${1:-2026Q1}"   # e.g. 2026Q1, 2023Q2
FEED_ARCH="${2:-x64}"         # e.g. x64, arm
PARALLEL_DOWNLOADS=16         # concurrent downloads per feed
BASE_URL="https://download.ni.com/ni-linux-rt/feeds"
BASE_DIR="./ni-linux-rt-${FEED_VERSION}"

# CPU-tune subfeed (third component alongside "all" and FEED_ARCH).
# Override with the TUNE_ARCH env var when targeting non-default hardware.
case "$FEED_ARCH" in
  x64) TUNE_ARCH_DEFAULT="core2-64" ;;
  arm) TUNE_ARCH_DEFAULT="cortexa9-vfpv3" ;;
  *)   TUNE_ARCH_DEFAULT="" ;;
esac
TUNE_ARCH="${TUNE_ARCH:-$TUNE_ARCH_DEFAULT}"

CURL_OPTS=(--retry 3 --retry-delay 2 --retry-connrefused -sf)
# ──────────────────────────────────────────────────────────────────────────────

FEED_ROOT="${BASE_URL}/${FEED_VERSION}/${FEED_ARCH}"

FEEDS=(
  "${FEED_ROOT}/extra/all"
  "${FEED_ROOT}/extra/${FEED_ARCH}"
  "${FEED_ROOT}/main/all"
  "${FEED_ROOT}/main/${FEED_ARCH}"
)
if [ -n "$TUNE_ARCH" ]; then
  FEEDS+=(
    "${FEED_ROOT}/extra/${TUNE_ARCH}"
    "${FEED_ROOT}/main/${TUNE_ARCH}"
  )
fi

# ─── Tmpfile cleanup ──────────────────────────────────────────────────────────
WORK_FILE=""
COUNTER_FILE=""
cleanup() {
  [ -n "$WORK_FILE" ] && rm -f "$WORK_FILE"
  [ -n "$COUNTER_FILE" ] && rm -f "$COUNTER_FILE"
}
trap cleanup EXIT

# ─── Download + verify helper (exported for xargs subshells) ──────────────────
# Reads PROGRESS_COUNTER (file) and PROGRESS_TOTAL (int) from env to emit
# "[N/TOTAL]" progress. Counter file is append-only; single-byte appends are
# atomic on POSIX so we don't need locking — wc -l reports a consistent count.
download_and_verify() {
  local url="$1" dest="$2" expected="$3"
  local name status n
  name=$(basename "$dest")
  mkdir -p "$(dirname "$dest")"

  if ! curl --retry 3 --retry-delay 2 --retry-connrefused -sf "$url" -o "$dest"; then
    status="FAIL (download error)"
  else
    local actual
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
      status="FAIL (sha256 mismatch)"
      rm -f "$dest"
    else
      status="GET "
    fi
  fi

  echo "x" >> "$PROGRESS_COUNTER"
  n=$(wc -l < "$PROGRESS_COUNTER")
  printf "    [%d/%d] %s %s\n" "$n" "$PROGRESS_TOTAL" "$status" "$name"
  [[ "$status" == FAIL* ]] && return 1 || return 0
}
export -f download_and_verify

for FEED in "${FEEDS[@]}"; do
  SUBPATH=$(echo "$FEED" | sed 's|https://download.ni.com/||')
  DEST="$BASE_DIR/$SUBPATH"
  mkdir -p "$DEST"

  echo "==> Fetching index from $FEED"
  if curl "${CURL_OPTS[@]}" "$FEED/Packages.gz" -o "$DEST/Packages.gz"; then
    gunzip -fc "$DEST/Packages.gz" > "$DEST/Packages"
  else
    echo "    Packages.gz not found, trying Packages..."
    curl "${CURL_OPTS[@]}" "$FEED/Packages" -o "$DEST/Packages"
  fi

  PKGFILE="$DEST/Packages"
  if [ ! -s "$PKGFILE" ]; then
    echo "    WARNING: No package index for $FEED, skipping."
    continue
  fi

  curl "${CURL_OPTS[@]}" "$FEED/Packages.stamps" -o "$DEST/Packages.stamps" 2>/dev/null || true

  # Extract one "Filename<TAB>SHA256" per stanza. Fields can appear in any
  # order within a stanza, so we collect both and emit on the blank separator.
  # Materialize work list into a tmpfile so we can report total count.
  WORK_FILE=$(mktemp)
  COUNTER_FILE=$(mktemp)

  awk '
    /^Filename:/  { fn = $2 }
    /^SHA256sum:/ { sum = $2 }
    /^$/ {
      if (fn != "" && sum != "") print fn "\t" sum
      fn = ""; sum = ""
    }
    END {
      if (fn != "" && sum != "") print fn "\t" sum
    }
  ' "$PKGFILE" | while IFS=$'\t' read -r REL SHA; do
    LOCAL="$DEST/$REL"
    if [ -f "$LOCAL" ]; then
      ACTUAL=$(sha256sum "$LOCAL" | awk '{print $1}')
      if [ "$ACTUAL" = "$SHA" ]; then
        echo "    SKIP: $(basename "$REL")" >&2
        continue
      fi
      echo "    STALE: $(basename "$REL") (re-downloading)" >&2
    fi
    printf '%s\t%s\t%s\n' "$FEED/$REL" "$LOCAL" "$SHA"
  done > "$WORK_FILE"

  TOTAL=$(wc -l < "$WORK_FILE")
  if [ "$TOTAL" -eq 0 ]; then
    echo "==> Nothing to download from $FEED (all packages up to date)"
  else
    echo "==> Downloading $TOTAL packages from $FEED"
    : > "$COUNTER_FILE"
    PROGRESS_COUNTER="$COUNTER_FILE" PROGRESS_TOTAL="$TOTAL" \
      xargs -a "$WORK_FILE" -P "$PARALLEL_DOWNLOADS" -n3 \
        bash -c 'download_and_verify "$1" "$2" "$3"' _
  fi

  cleanup
  echo "==> Done: $FEED"
  echo ""
done

echo "All feeds complete: ${FEED_VERSION}/${FEED_ARCH} (tune=${TUNE_ARCH:-<none>})"
