FROM ubuntu:24.04 AS source-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_JOBS=1
ARG REPO_CHIA_BLOCKCHAIN
ARG REPO_CHIA_RS
ARG REPO_CHIAPOS
ARG REPO_CHIAVDF
ARG REPO_CHIABIP158
ARG REPO_CLVM_RS
ARG REPO_CLVM
ARG REPO_CLVM_TOOLS
ARG REPO_CHIALISP
ARG REPO_CHIA_PUZZLES

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH \
    BUILD_JOBS=${BUILD_JOBS} \
    REPO_CHIA_BLOCKCHAIN=${REPO_CHIA_BLOCKCHAIN} \
    REPO_CHIA_RS=${REPO_CHIA_RS} \
    REPO_CHIAPOS=${REPO_CHIAPOS} \
    REPO_CHIAVDF=${REPO_CHIAVDF} \
    REPO_CHIABIP158=${REPO_CHIABIP158} \
    REPO_CLVM_RS=${REPO_CLVM_RS} \
    REPO_CLVM=${REPO_CLVM} \
    REPO_CLVM_TOOLS=${REPO_CLVM_TOOLS} \
    REPO_CHIALISP=${REPO_CHIALISP} \
    REPO_CHIA_PUZZLES=${REPO_CHIA_PUZZLES}

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git file unzip \
      python3 python3-dev python3-venv python3-pip \
      build-essential cmake ninja-build pkg-config \
      autoconf automake libtool clang libclang-dev \
      libgmp-dev libssl-dev libboost-all-dev libflint-dev libyaml-cpp-dev \
      libsqlite3-dev libffi-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
      libreadline-dev libncurses-dev libevent-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable

COPY src/ /build/src/
COPY scripts/sources.sh /usr/local/bin/sources
COPY scripts/configure_node.cpp scripts/lab_signal.cpp /tmp/sia-helpers/

RUN chmod 0755 /usr/local/bin/sources \
    && /usr/local/bin/sources \
    && g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic \
         /tmp/sia-helpers/configure_node.cpp -lyaml-cpp -o /usr/local/bin/sia-config \
    && g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic \
         /tmp/sia-helpers/lab_signal.cpp -o /usr/local/bin/sia-signal \
    && rm -rf /tmp/sia-helpers /build/wheels /build/cargo-target /build/runtime

FROM ubuntu:24.04 AS binary-runtime

ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/chia-blockchain/.venv/bin:/opt/chia-blockchain:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates jq tini \
      python3 python3-venv \
      libgmp-dev libssl-dev libboost-all-dev libflint-dev libyaml-cpp-dev \
      libsqlite3-dev libffi-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
      libreadline-dev libncurses-dev libevent-dev \
      iproute2 iptables iputils-ping netcat-openbsd dnsutils \
      procps psmisc lsof sqlite3 xz-utils file \
    && rm -rf /var/lib/apt/lists/*

COPY --from=source-builder /opt/chia-blockchain/ /opt/chia-blockchain/
COPY --from=source-builder /usr/local/bin/sia-config /usr/local/bin/sia-config
COPY --from=source-builder /usr/local/bin/sia-signal /usr/local/bin/sia-signal

WORKDIR /workspace
