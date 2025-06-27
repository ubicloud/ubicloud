FROM ruby:3.2-slim AS builder

RUN apt update && apt install -y build-essential

WORKDIR /app

COPY Gemfile ubi-csi.gemspec ./
RUN bundle config set without 'development test' && bundle install

FROM ruby:3.2-slim

COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /app

COPY lib/ ./lib/
COPY bin/ ./bin/

ENTRYPOINT ["/usr/local/bin/ruby", "/app/bin/ubi-csi-server"]
