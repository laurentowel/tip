FROM rust:1.89-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY testkit/ testkit/
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      fontconfig fonts-noto-core ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/tip-server /usr/local/bin/
WORKDIR /project
ENTRYPOINT ["tip-server"]
