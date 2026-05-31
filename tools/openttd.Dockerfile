# Headless OpenTTD 15.3 for unattended AI match scoring.
# Runs with the `null` video/sound drivers (-v null:ticks=N) so no GUI / SDL
# display is needed; debug output (-d script=N) goes to stdout for capture.
#
#   docker build -t mvb-ottd -f tools/openttd.Dockerfile .
#
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils unzip \
        libsdl2-2.0-0 libfontconfig1 libfreetype6 libpng16-16 liblzma5 zlib1g libstdc++6 libgomp1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

ARG OTTD_VER=15.3
RUN curl -fsSL "https://cdn.openttd.org/openttd-releases/${OTTD_VER}/openttd-${OTTD_VER}-linux-generic-amd64.tar.xz" \
        -o /tmp/o.tar.xz \
 && mkdir -p /opt/openttd \
 && tar -xf /tmp/o.tar.xz -C /opt/openttd --strip-components=1 \
 && rm /tmp/o.tar.xz \
 && ln -s /opt/openttd/openttd /usr/local/bin/openttd

# Free base graphics (the release tarball ships only the orig_* sets, which
# need the original TTD files). OpenGFX is the free replacement.
ARG OGFX_VER=7.1
RUN curl -fsSL "https://cdn.openttd.org/opengfx-releases/${OGFX_VER}/opengfx-${OGFX_VER}-all.zip" \
        -o /tmp/ogfx.zip \
 && unzip -o /tmp/ogfx.zip -d /tmp/ogfx \
 && (tar -xf /tmp/ogfx/*.tar -C /opt/openttd/baseset 2>/dev/null || cp /tmp/ogfx/*.tar /opt/openttd/baseset/) \
 && rm -rf /tmp/ogfx /tmp/ogfx.zip

WORKDIR /opt/openttd
