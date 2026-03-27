ARG EMACS_VERSION=29.4
ARG MISE_PLATFORM=linux/amd64
FROM --platform=${MISE_PLATFORM} jdxcode/mise AS mise
FROM silex/emacs:${EMACS_VERSION}
RUN apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1 && rm -rf /var/lib/apt/lists/* \
    && git config --global --add safe.directory '*'
COPY --from=mise /usr/local/bin/mise /usr/local/bin/mise
