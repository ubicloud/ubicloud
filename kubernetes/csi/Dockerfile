FROM ruby:4.0.2-slim AS builder

RUN apt update && apt install -y build-essential

WORKDIR /app

COPY Gemfile ubi-csi.gemspec ./
RUN bundle config set without 'development test' && bundle install

FROM ruby:4.0.2-slim

ARG UBIBLK_VERSION=v0.5.1
ARG UBIBLK_SHA256=7b82f4769a7ee52b1fa71d17f12dbe02a4795e4bdb5e8fe4cea98bb3a7913972

RUN apt update && apt install -y apt-transport-https ca-certificates curl gnupg openssh-client e2fsprogs xfsprogs
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
RUN echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list && \
    chmod 644 /etc/apt/sources.list.d/kubernetes.list
RUN apt update && apt install -y kubectl iputils-ping dnsutils curl telnet \
    net-tools iproute2 netcat-openbsd mtr-tiny traceroute

RUN curl -fsSL -o /tmp/ubiblk.tar.gz "https://github.com/ubicloud/ubiblk/releases/download/${UBIBLK_VERSION}/ubiblk-x64.tar.gz" && \
    echo "${UBIBLK_SHA256}  /tmp/ubiblk.tar.gz" | sha256sum -c - && \
    mkdir -p "/opt/ubiblk/${UBIBLK_VERSION}" && \
    tar xzf /tmp/ubiblk.tar.gz --no-same-owner -C "/opt/ubiblk/${UBIBLK_VERSION}" ublk-backend init-metadata remote-stripe-server && \
    rm /tmp/ubiblk.tar.gz

COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /app

COPY lib/ ./lib/
COPY bin/ ./bin/

ENTRYPOINT ["/usr/local/bin/ruby", "/app/bin/ubi-csi-server"]
