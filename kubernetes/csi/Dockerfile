FROM ruby:3.2-slim AS builder

RUN apt update && apt install -y build-essential

WORKDIR /app

COPY Gemfile ubi-csi.gemspec ./
RUN bundle config set without 'development test' && bundle install

FROM ruby:3.2-slim

RUN apt update && apt install -y apt-transport-https ca-certificates curl gnupg openssh-client
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
RUN echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list && \
    chmod 644 /etc/apt/sources.list.d/kubernetes.list
RUN  apt update && apt install -y kubectl

COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /app

COPY lib/ ./lib/
COPY bin/ ./bin/

ENTRYPOINT ["/usr/local/bin/ruby", "/app/bin/ubi-csi-server"]
