# Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Base tools & Flutter deps (official docs: curl, git, unzip, xz-utils, zip, etc.)
# + build tools often needed by Flutter plugins and CMake-based packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip \
    clang cmake ninja-build pkg-config build-essential \
    libgtk-3-dev libglu1-mesa \
    openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

# (Optional) verify glibc version in the image during build logs
RUN ldd --version || true

# Install Flutter from the official repo and switch to channel "main"
# (Flutter docs: install manually + upgrade on current channel)
# Shallow clone to keep image small; you can remove --depth for full history if you plan to pin by commit later.
RUN git clone --depth 1 -b main https://github.com/flutter/flutter.git ${FLUTTER_HOME} \
 && flutter --version \
 && flutter config --enable-web \
 && flutter precache --linux --web \
 && flutter upgrade

# Turn off analytics in CI
RUN flutter config --no-analytics || true

# Helpful check and warmup of the toolchain
RUN dart --version && flutter doctor -v || true

# Default workdir for GitHub Actions workspace mount
WORKDIR /work