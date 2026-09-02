ARG CHIA_BINARY_IMAGE=chia-binaries:built
FROM ${CHIA_BINARY_IMAGE} AS chia-binaries

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/chia-blockchain/.venv/bin:/opt/chia-blockchain:$PATH \
    PYTHONUNBUFFERED=1

FROM chia-binaries AS assets
COPY scripts/lab-mnemonic.txt scripts/make-plots.sh scripts/make-certs.sh /opt/chia/
RUN chmod 0755 /opt/chia/make-plots.sh /opt/chia/make-certs.sh \
    && /opt/chia/make-plots.sh \
    && /opt/chia/make-certs.sh

FROM chia-binaries AS runtime
ENV CHIA_ROOT=/run/chia/root \
    CHIA_KEYS_ROOT=/run/chia/keys \
    CHIA_HOME=/opt/chia

COPY scripts/entrypoint.sh scripts/lab-mnemonic.txt /opt/chia/
COPY controls/ /workspace/controls/
COPY scenarios/ /workspace/scenarios/
RUN chmod 0755 \
      /opt/chia/entrypoint.sh \
      /workspace/controls/logging.sh \
      /workspace/controls/actions.sh \
      /workspace/controls/network.sh \
      /workspace/controls/scenario-tie.sh \
      /workspace/scenarios/*.sh \
    && ln -s /opt/chia/entrypoint.sh /usr/local/bin/chia-entrypoint \
    && mkdir -p /opt/chia/plots

WORKDIR /workspace
