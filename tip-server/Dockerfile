FROM rust:1.89-slim AS builder
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      musl-tools perl make && \
    rustup target add x86_64-unknown-linux-musl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY testkit/ testkit/
RUN cargo build --release --target x86_64-unknown-linux-musl

FROM scratch
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/tip-server-typst /tip-server-typst
ENTRYPOINT ["/tip-server-typst"]
