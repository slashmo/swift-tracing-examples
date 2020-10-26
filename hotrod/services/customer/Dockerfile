# Builder 🏗
FROM swift:5.3 as builder

RUN apt-get -qq update && apt-get install -y \
  libssl-dev \
  zlib1g-dev \
  && rm -r /var/lib/apt/lists/*

WORKDIR /app

COPY Sources Sources
COPY Package.swift .
COPY Package.resolved .

RUN swift package resolve

RUN mkdir -p /build/lib && cp -R /usr/lib/swift/linux/*.so* /build/lib
RUN swift build -c release && mv `swift build -c release --show-bin-path` /build/bin

# Release 🚢
FROM ubuntu:18.04

ARG BUILD_DATE
LABEL org.label-schema.build-date=$BUILD_DATE

LABEL maintainer="hi@slashmo.codes"
LABEL description="HOT R.O.D. Customer"

RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libatomic1 \
  libbsd0 \
  libcurl4 \
  libicu60 \
  libxml2 \
  libz-dev \
  tzdata \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/bin/Serve .
COPY --from=builder /build/lib/* /usr/lib/

ENTRYPOINT [ \
  "./Serve", \
  "--help" \
  ]
