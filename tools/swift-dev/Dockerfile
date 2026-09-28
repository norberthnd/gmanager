# Swift toolchain for running the packages' tests on Linux (CI or cloud sessions).
FROM swift:6.4
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
