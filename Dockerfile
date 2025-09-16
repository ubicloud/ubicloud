FROM docker.io/library/node:24.6-alpine3.21 AS frontend-builder
WORKDIR /app
COPY tailwind.config.js package.json package-lock.json ./
COPY views/ ./views/
COPY assets/ ./assets/
COPY helpers/web.rb ./helpers/web.rb
RUN npm ci
RUN npm run prod


FROM docker.io/library/ruby:3.4.6-alpine3.21 AS bundler
# Install build dependencies
# - build-base, git, curl: To ensure certain gems can be compiled
# - postgresql-dev: Required for postgresql gem
RUN apk update --no-cache && \
    apk add build-base git curl postgresql-dev libffi-dev --no-cache
WORKDIR /app
COPY Gemfile Gemfile.lock ./

RUN bundle install


FROM docker.io/library/ruby:3.4.6-alpine3.21
# Install runtime dependencies
# - tzdata: The public-domain time zone database
# - curl: Required for healthcheck and some basic operations
# - postgresql-client: Required for postgresql gem at runtime
# - gcompat: Required for nokogiri gem at runtime. https://nokogiri.org/tutorials/installing_nokogiri.html#linux-musl-error-loading-shared-library
# - foreman: Helps to start different parts of app based on Procfile
RUN apk update --no-cache && \
    apk add tzdata curl postgresql-client gcompat libffi --no-cache && \
    gem install foreman

RUN adduser -D ubicloud && \
    mkdir /app && \
    chown ubicloud:ubicloud /app
# Don't use root to run our app as extra line of defense
USER ubicloud
WORKDIR /app

# Copy built assets from builders
COPY --from=bundler /usr/local/bundle/ /usr/local/bundle/
COPY --chown=ubicloud --from=frontend-builder /app/assets/css/app.css /app/assets/css/app.css
COPY --chown=ubicloud . /app

ENV RACK_ENV=production
ENV PORT=3000

EXPOSE 3000

CMD ["foreman", "start"]
