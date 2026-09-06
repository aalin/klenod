# syntax=docker/dockerfile:1

ARG KLENOD_VERSION="0.0.7"

FROM ruby:4.0.6-slim AS build

ARG KLENOD_VERSION

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates imagemagick libheif-plugin-aomdec libheif-plugin-aomenc libmagickwand-dev libsodium23 libssl-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile ./

RUN sed -i "s/, path: \"[^\"]*\"/, \"${KLENOD_VERSION}\"/" Gemfile \
  && bundle install

COPY bin ./bin
COPY lib ./lib
COPY src ./src
COPY types ./types
COPY tsconfig.json ./

RUN bundle exec bin/build

FROM ruby:4.0.6-alpine3.24 AS runtime-gems

ARG KLENOD_VERSION

ENV GEM_HOME=/usr/local/bundle
ENV PATH="${GEM_HOME}/bin:${PATH}"
ENV BUNDLE_WITHOUT=development:build

WORKDIR /app

RUN apk add --no-cache build-base ca-certificates libsodium-dev openssl-dev pkgconf

COPY Gemfile ./

RUN sed -i "s/, path: \"[^\"]*\"/, \"${KLENOD_VERSION}\"/" Gemfile \
  && bundle install

FROM ruby:4.0.6-alpine3.24 AS runtime

ENV GEM_HOME=/usr/local/bundle
ENV PATH="${GEM_HOME}/bin:${PATH}"
ENV HOST=0.0.0.0
ENV PORT=9292
ENV TLS=false

WORKDIR /app

RUN apk add --no-cache ca-certificates libsodium

COPY --from=runtime-gems /usr/local/bundle /usr/local/bundle
COPY --from=build /app/bin/server ./bin/server
COPY --from=build /app/dist ./dist
COPY --from=build /app/lib ./lib
COPY --from=build /app/src ./src

EXPOSE 9292

CMD ["ruby", "--jit", "bin/server"]
