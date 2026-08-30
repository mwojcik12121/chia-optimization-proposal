# Chia binary build environment

This environment compiles Chia executables and exports them as a portable archive for the test environment.

## Recommended resources

| CPU | RAM | Swap | Free disk | Build jobs |
|:---:|:---:|:---:|:---:|:---:|
| 4 cores | 8 GB | optional | 15–20 GB | 2 |

Practical verification:
Build was done on a machine with 32 GB RAM, 12 CPU cores and around 800 GB of free disk space - it was done with 4 parallel jobs and took around 9 minutes.

## Build

1. Place repositories in `src/` folder

2. Run:

```bash
./build.sh --chia-blockchain NAME --chia-rs NAME --chiapos NAME --chiavdf NAME --chiabip158 NAME --clvm-rs NAME --clvm NAME --clvm-tools NAME --chialisp NAME --chia-puzzles NAME --build-jobs 4
```

3. After a successful build, the `bin/` directory will contain:

```text
bin/chia-binaries.tar.gz
```
