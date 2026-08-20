# syntax=docker/dockerfile:1
FROM ghcr.io/linuxserver/baseimage-kasmvnc:ubuntunoble

# Empty = install whatever is current in the Anycubic repo.
# Pin with: docker compose build --build-arg ASN_VERSION=1.3.96
ARG ASN_VERSION=

LABEL maintainer="david@arond.ro"
LABEL org.opencontainers.image.source="https://github.com/ANYCUBIC-3D/AnycubicSlicer"
LABEL org.opencontainers.image.description="Anycubic Slicer Next (OrcaSlicer fork) served over the web via KasmVNC"

ENV TITLE="Anycubic Slicer Next" \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    GDK_BACKEND=x11 \
    START_DOCKER=false \
    NO_FULL=true

RUN \
  echo "**** add kisak-mesa PPA (noble ships Mesa 24.0; gfx115x needs >= 24.2) ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    software-properties-common && \
  add-apt-repository -y ppa:kisak/kisak-mesa && \
  echo "**** add anycubic apt repo (unsigned, same as upstream installer) ****" && \
  echo "deb [trusted=yes] https://cdn-universe-slicer.anycubic.com/prod noble main" \
    > /etc/apt/sources.list.d/acnext.list && \
  echo "**** install anycubic slicer next + runtime deps ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    "anycubicslicernext${ASN_VERSION:+=$ASN_VERSION}" \
    dbus-x11 \
    desktop-file-utils \
    fonts-noto-cjk \
    fonts-noto-core \
    gstreamer1.0-gl \
    gstreamer1.0-gtk3 \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-pulseaudio \
    gstreamer1.0-x \
    libgl1-mesa-dri \
    libglu1-mesa \
    libglx-mesa0 \
    mesa-utils \
    mesa-vulkan-drivers \
    xdg-utils && \
  echo "**** harden: no terminal emulator on the web desktop ****" && \
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    xterm 2>/dev/null || true && \
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y && \
  echo "**** brand the web client ****" && \
  cp /usr/share/AnycubicSlicerNext/resources/images/AnycubicSlicer.png /kclient/public/icon.png && \
  echo "**** cleanup ****" && \
  apt-get autoclean && \
  rm -rf \
    /config/.cache \
    /config/.launchpadlib \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/*

# root/etc/s6-overlay/.../init-asn-perms fixes ownership of the slicer's
# resource tree at container start -- it cannot be done here, because
# build-time `abc` is uid 911 and init-adduser remaps it to PUID at runtime.
COPY root/ /

EXPOSE 3000 3001
VOLUME /config
