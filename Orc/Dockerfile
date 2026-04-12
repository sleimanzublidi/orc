FROM swift:6.1-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    libicu-dev \
    zip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Core/ Core/
COPY CLI/ CLI/
COPY Plugins/ Plugins/

# Default: build debug and run tests
CMD ["sh", "-c", "swift build && swift test"]
