# syntax=docker/dockerfile:1

FROM ruby:4.0.6-slim AS klenod-gems

WORKDIR /repo

COPY .ruby-version KLENOD_VERSION ./
COPY gems ./gems

RUN mkdir -p /tmp/klenod-gems \
  && cd gems/klenod-runtime \
  && gem build klenod-runtime.gemspec --output /tmp/klenod-gems/klenod-runtime.gem \
  && cd ../klenod-rack \
  && gem build klenod-rack.gemspec --output /tmp/klenod-gems/klenod-rack.gem \
  && cd ../klenod-build \
  && gem build klenod-build.gemspec --output /tmp/klenod-gems/klenod-build.gem \
  && cd ../klenod \
  && gem build klenod.gemspec --output /tmp/klenod-gems/klenod.gem

FROM ruby:4.0.6-slim AS build

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates imagemagick libmagickwand-dev libsodium23 libssl-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

COPY --from=klenod-gems /tmp/klenod-gems /tmp/klenod-gems
COPY . .

WORKDIR /app/example/web

RUN bundle install \
  && bundle exec bin/build

FROM ruby:4.0.6-alpine3.24 AS runtime-gems

ENV GEM_HOME=/usr/local/bundle
ENV PATH="${GEM_HOME}/bin:${PATH}"

RUN apk add --no-cache build-base ca-certificates libsodium-dev openssl-dev pkgconf

COPY --from=klenod-gems /tmp/klenod-gems /tmp/klenod-gems

RUN gem install --no-document /tmp/klenod-gems/klenod-runtime.gem \
  && gem install --no-document /tmp/klenod-gems/klenod-rack.gem \
  && gem install --no-document async-http -v "~> 0.95.1" \
  && gem install --no-document rbnacl -v "~> 7.1" \
  && gem install --no-document rouge -v "~> 5.0" \
  && rm -rf /tmp/klenod-gems

FROM ruby:4.0.6-alpine3.24 AS runtime

ENV GEM_HOME=/usr/local/bundle
ENV PATH="${GEM_HOME}/bin:${PATH}"
ENV HOST=0.0.0.0
ENV PORT=9292

WORKDIR /app

RUN apk add --no-cache ca-certificates libsodium openssl

COPY --from=runtime-gems /usr/local/bundle /usr/local/bundle
COPY --from=build /app/example/web/bin/server ./bin/server
COPY --from=build /app/example/web/dist ./dist
COPY --from=build /app/example/web/lib ./lib
COPY --from=build /app/example/web/src ./src

EXPOSE 9292

CMD ["ruby", "--jit", "bin/server"]
