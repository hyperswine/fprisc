# FP-RISC Linux toolchain build: Debian bookworm (glibc 2.36) + GHC 9.8.2 (ghcup)
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
# libcurl >= 8.4 (fp-risc.cabal) comes from bookworm-backports; the rest of
# the system, and so the glibc floor, stays bookworm (2.36)
RUN echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates git pkg-config patchelf binutils file xz-utils \
      libgmp-dev libffi-dev libncurses-dev zlib1g-dev cmake libssl-dev openssh-client \
      libgit2-dev libarchive-dev libegl-dev libgl-dev libarchive-tools \
    && apt-get install -y --no-install-recommends -t bookworm-backports libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*
# libgit2 >= 1.9 (fp-risc.cabal) is newer than bookworm and its backports
# (1.8.4): built from the release source; SSH through the system ssh binary
RUN curl -sSL https://github.com/libgit2/libgit2/archive/refs/tags/v1.9.1.tar.gz | tar -xz -C /tmp \
 && cmake -S /tmp/libgit2-1.9.1 -B /tmp/lg2 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/libgit2-1.9.1 \
      -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=exec -DUSE_HTTPS=OpenSSL \
 && cmake --build /tmp/lg2 -j4 && cmake --install /tmp/lg2 \
 && mkdir -p /opt/libgit2-1.9.1/share/licenses && cp /tmp/libgit2-1.9.1/COPYING /opt/libgit2-1.9.1/share/licenses/ \
 && rm -rf /tmp/libgit2-1.9.1 /tmp/lg2
ENV PKG_CONFIG_PATH=/opt/libgit2-1.9.1/lib/pkgconfig LD_LIBRARY_PATH=/opt/libgit2-1.9.1/lib
ENV GHCUP_INSTALL_BASE_PREFIX=/opt BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_GHC_VERSION=9.8.2 BOOTSTRAP_HASKELL_CABAL_VERSION=3.12.1.0 \
    BOOTSTRAP_HASKELL_MINIMAL=1
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh \
 && /opt/.ghcup/bin/ghcup install ghc 9.8.2 --set && /opt/.ghcup/bin/ghcup install cabal 3.12.1.0 --set
ENV PATH=/opt/.ghcup/bin:$PATH
