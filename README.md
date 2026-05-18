# nilinuxrt-repo-tools

Shell scripts for downloading and mirroring [NI Linux RT](http://download.ni.com/ni-linux-rt/feeds) package feeds. Useful for air-gapped deployments, local mirrors, or selectively caching packages with dependency resolution.

## Scripts

| Script | Purpose |
|---|---|
| `nilinuxrt-fetch.sh` | Download packages matching a regex pattern, with automatic dependency resolution |
| `nilinuxrt-mirror.sh` | Mirror all packages from every feed for a given version and architecture |

## Requirements

- `bash`
- `curl`
- `python3` (required by `nilinuxrt-fetch.sh` for dependency resolution)
- `gunzip`

## Usage

### nilinuxrt-fetch.sh

Downloads packages matching a regex pattern and automatically resolves and downloads their dependencies.

```
./nilinuxrt-fetch.sh [FEED_VERSION] [ARCH] [PKG_PATTERN]
```

| Argument | Default | Description |
|---|---|---|
| `FEED_VERSION` | `2026Q1` | Feed quarter, e.g. `2025Q4`, `2024Q2` |
| `ARCH` | `x64` | Target architecture: `x64` or `arm` |
| `PKG_PATTERN` | `.*` (all) | ERE regex matched against package names |

Output is written to `./ni-linux-rt-<FEED_VERSION>/`.

**Examples**

Download all Python 3 packages and their dependencies from the default feed:
```bash
./nilinuxrt-fetch.sh 2026Q1 x64 "^python3"
```

Download GCC, Make, and all their dependencies:
```bash
./nilinuxrt-fetch.sh 2026Q1 x64 "^gcc|^make"
```

Download all packages from the 2025Q4 ARM feed (no filter):
```bash
./nilinuxrt-fetch.sh 2025Q4 arm ".*"
```

Download a specific package by exact name:
```bash
./nilinuxrt-fetch.sh 2026Q1 x64 "^libssl1\.1$"
```

---

### nilinuxrt-mirror.sh

Mirrors the complete set of packages from all feeds (main and extra) for a given version and architecture. No filtering — downloads everything.

```
./nilinuxrt-mirror.sh [FEED_VERSION] [ARCH]
```

| Argument | Default | Description |
|---|---|---|
| `FEED_VERSION` | `2026Q1` | Feed quarter, e.g. `2025Q4`, `2024Q2` |
| `ARCH` | `x64` | Target architecture: `x64` or `arm` |

Output is written to `./ni-linux-rt-<FEED_VERSION>/`.

**Examples**

Mirror the full 2026Q1 x64 feed:
```bash
./nilinuxrt-mirror.sh 2026Q1 x64
```

Mirror the 2025Q2 ARM feed:
```bash
./nilinuxrt-mirror.sh 2025Q2 arm
```

Mirror using all defaults:
```bash
./nilinuxrt-mirror.sh
```

---

## Output Structure

Both scripts produce a local directory tree that mirrors the upstream feed layout:

```
ni-linux-rt-2026Q1/
└── ni-linux-rt/
    └── feeds/
        └── 2026Q1/
            └── x64/
                ├── main/
                │   ├── all/
                │   │   ├── Packages
                │   │   ├── Packages.gz
                │   │   ├── Packages.stamps
                │   │   └── *.ipk
                │   ├── x64/
                │   └── core2-64/
                └── extra/
                    ├── all/
                    ├── x64/
                    └── core2-64/
```

Already-downloaded packages are skipped on subsequent runs, making re-runs safe for incremental updates.

## Parallel Downloads

Both scripts download packages concurrently:

- `nilinuxrt-fetch.sh` — 8 parallel downloads (configurable via `PARALLEL_DOWNLOADS` in the script)
- `nilinuxrt-mirror.sh` — 16 parallel downloads (configurable via `PARALLEL_DOWNLOADS` in the script)
