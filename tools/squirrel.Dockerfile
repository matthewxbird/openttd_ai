# Builds a Squirrel 3.x interpreter (`sq`) and bakes it into a tiny image.
# Used to run the pure-module unit tests in tests/ without installing a
# compiler on the host. See tools/run_tests.ps1.
#
#   docker build -t mvb-sq -f tools/squirrel.Dockerfile .
#   docker run --rm -v "${PWD}:/work" mvb-sq tests/run_all.nut
#
FROM gcc:13 AS build
RUN git clone --depth 1 https://github.com/albertodemichelis/squirrel.git /squirrel \
 && cd /squirrel && make sq64 \
 && cp bin/sq /usr/local/bin/sq
WORKDIR /work
ENTRYPOINT ["sq"]
