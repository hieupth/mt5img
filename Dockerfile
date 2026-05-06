FROM ghcr.io/linuxserver/baseimage-kasmvnc:debianbookworm

ENV TITLE="MetaTrader 5"
ENV WINEDEBUG=-all
ENV WINEPREFIX=/config/.wine

ARG WINE_BRANCH=devel
ARG WINE_VERSION=11.8~bookworm-1
# hadolint ignore=DL3008,DL3015
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg2 && \
    mkdir -p /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq-archive.key] https://dl.winehq.org/wine-builds/debian/ bookworm main" \
        > /etc/apt/sources.list.d/winehq.list && \
    apt-get update && \
    apt-get install -y --install-recommends winehq-${WINE_BRANCH}=${WINE_VERSION} && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh

COPY root/ /
COPY scripts/start.sh /Metatrader/start.sh

EXPOSE 3000
