FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        unzip git-lfs zlib1g-dev libgl1-mesa-dev curl wget && \
    rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=\$PATH:\$ANDROID_HOME/emulator:\$ANDROID_HOME/platform-tools
