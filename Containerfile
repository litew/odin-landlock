# Containerfile (odin-dev-2026-11a)
#
# Pinned Odin nightly toolchain image for local gate verification (phase 01, D-03).
# The toolchain source is the exact release tarball, sha256-verified at image build
# (T1: supply-chain control — a digest mismatch fails this build loudly, never warns).
# Repo source is never COPY'd in: bind-mount it at run time (-v "$PWD:/src:Z" -w /src).
# The image is local-only (localhost/odin-dev-2026-11a); CI uses laytan/setup-odin@v2
# with the same release tag (D-01).
FROM docker.io/library/fedora:latest

# glibc base (the release binary is glibc-linked); clang links user code for
# odin build/test; curl fetches the pinned release tarball.
RUN dnf install -y curl clang && dnf clean all

# Release artifact identity (D-02): odin-linux-amd64-dev-2026-11a.tar.gz,
# sha256 65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618
# (byte-identical to the dev-2026-11 linux-amd64 asset).
ARG ODIN_SHA256=65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618

RUN curl -fsSL -o /tmp/odin.tar.gz \
      https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz \
 && echo "${ODIN_SHA256}  /tmp/odin.tar.gz" | sha256sum --check - \
 && mkdir -p /opt/odin && tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 \
 && rm /tmp/odin.tar.gz

ENV PATH="/opt/odin:${PATH}"
