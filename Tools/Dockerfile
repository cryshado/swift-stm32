# Builds patched STM32 SVD files from a pinned commit of stm32-rs.

ARG STM32_RS_COMMIT=8d35f8b65390da7045b3c4948ac9caffc620c648
ARG SVDTOOLS_VERSION=0.5.0

FROM rust:slim-bookworm AS svdtools

ARG SVDTOOLS_VERSION

RUN cargo install svdtools --version "${SVDTOOLS_VERSION}" --locked --root /opt/svdtools

FROM debian:bookworm-slim AS stm32rs

ARG STM32_RS_COMMIT

RUN apt-get update && \
    apt-get install -y --no-install-recommends bash ca-certificates git make ruby unzip && \
    rm -rf /var/lib/apt/lists/*

COPY --from=svdtools /opt/svdtools/bin/svdtools /usr/local/bin/svdtools

WORKDIR /build

RUN git init -q . && \
    git remote add origin https://github.com/stm32-rs/stm32-rs.git && \
    git fetch -q --depth 1 origin "${STM32_RS_COMMIT}" && \
    git checkout -q FETCH_HEAD

RUN make patch
COPY patches/ /build/patches/
RUN /build/patches/apply.rb

CMD ["true"]
