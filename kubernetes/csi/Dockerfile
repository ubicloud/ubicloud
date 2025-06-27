FROM ruby:3.4-slim AS builder

RUN apt update && apt install -y build-essential git

WORKDIR /app

COPY Gemfile ubi-csi.gemspec ./
RUN bundle install --without development test

FROM ruby:3.4-slim

COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /app

COPY lib/ ./lib/
COPY bin/ ./bin/

RUN useradd -m csi
USER csi

ENTRYPOINT ["/usr/local/bin/ruby", "/app/bin/ubi-csi-server"]
