# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG FLUTTER_VERSION=3.44.8
ARG FLUTTER_SHA256=672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d
ARG SOURCE_REPOSITORY=https://github.com/jci-products/flutter-dev
ARG TARGETARCH

LABEL org.opencontainers.image.title="JCI Flutter development image" \
      org.opencontainers.image.description="Flutter SDK and Linux tooling for CI analysis and unit tests" \
      org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.version="${FLUTTER_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    FLUTTER_HOME=/opt/flutter \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    HOME=/root \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PUB_CACHE=/root/.pub-cache \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/root/.pub-cache/bin:${PATH}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Flutter's prebuilt Linux SDK archive is x86-64. These packages cover
# flutter analyze/test plus the documented Linux desktop toolchain.
RUN set -eux; \
    if [[ -n "${TARGETARCH}" && "${TARGETARCH}" != "amd64" ]]; then \
      echo "Unsupported architecture: ${TARGETARCH}. Use --platform linux/amd64." >&2; \
      exit 1; \
    fi; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      git \
      libglu1-mesa \
      libgtk-3-dev \
      libstdc++-12-dev \
      ninja-build \
      openssh-client \
      pkg-config \
      unzip \
      xz-utils \
      zip; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    archive="/tmp/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"; \
    curl \
      --fail \
      --location \
      --retry 5 \
      --retry-all-errors \
      --output "${archive}" \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"; \
    echo "${FLUTTER_SHA256}  ${archive}" | sha256sum --check --strict; \
    tar --extract --xz --file "${archive}" --directory /opt --no-same-owner; \
    rm "${archive}"; \
    git config --system --add safe.directory "${FLUTTER_HOME}"; \
    flutter config --no-analytics; \
    flutter precache --linux; \
    flutter --version; \
    dart --version

WORKDIR /workspace

CMD ["bash"]
