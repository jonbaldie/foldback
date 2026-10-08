# Development image. Build and run it only as AGENTS.md "Development container" describes.
FROM haskell:9.12.2-slim-bookworm
ENV CABAL_DIR=/root/.cabal
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libgmp-dev \
    zlib1g-dev \
    git \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system safe.directory '*'

WORKDIR /workspace
# Dependencies live in the image. The project build goes to the dist-newstyle tmpfs at run time.
COPY foldback.cabal cabal.project ./
RUN cabal update && cabal build -j2 --only-dependencies --enable-tests all
LABEL dev-image=foldback
CMD ["cabal", "test", "foldback-test", "--test-show-details=always"]
