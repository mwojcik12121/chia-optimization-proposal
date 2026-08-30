ARG SIA_BINARY_IMAGE=chia-binaries:built
FROM ${SIA_BINARY_IMAGE} AS chia-binaries

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/chia-blockchain/.venv/bin:/opt/chia-blockchain:$PATH \
    PYTHONUNBUFFERED=1

FROM chia-binaries AS assets
COPY scripts/lab-mnemonic.txt scripts/make-plots.sh scripts/make-certs.sh /opt/sia/
RUN chmod 0755 /opt/sia/make-plots.sh /opt/sia/make-certs.sh \
    && /opt/sia/make-plots.sh \
    && /opt/sia/make-certs.sh

FROM chia-binaries AS runtime
ENV CHIA_ROOT=/run/chia/root \
    CHIA_KEYS_ROOT=/run/chia/keys \
    SIA_HOME=/opt/sia

COPY scripts/entrypoint.sh scripts/lab-mnemonic.txt /opt/sia/
COPY controls/ /workspace/controls/
COPY scenarios/ /workspace/scenarios/
RUN chmod 0755 \
      /opt/sia/entrypoint.sh \
      /workspace/controls/logging.sh \
      /workspace/controls/actions.sh \
      /workspace/controls/info.sh \
      /workspace/controls/network.sh \
      /workspace/controls/scenario-tie.sh \
      /workspace/scenarios/*.sh \
    && ln -s /opt/sia/entrypoint.sh /usr/local/bin/sia-entrypoint \
    && mkdir -p /opt/sia/plots

WORKDIR /workspace
