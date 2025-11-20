FROM ubuntu:24.04

ARG FLUTTER_VERSION=3.38.2

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      unzip \
      xz-utils \
      zip \
      clang \
      cmake \
      ninja-build \
      pkg-config \
      build-essential \
      libgtk-3-dev \
      libglu1-mesa \
      openjdk-17-jdk \
  && rm -rf /var/lib/apt/lists/*

RUN curl -L "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C /opt \
 && mv /opt/flutter /opt/flutter \
 && flutter --version \
 && flutter config --no-analytics \
 && flutter precache --linux \
 && dart --version \
 && flutter doctor -v || true

WORKDIR /work