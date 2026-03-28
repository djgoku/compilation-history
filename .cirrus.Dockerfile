ARG EMACS_VERSION=29.4
ARG MISE_PLATFORM=linux/amd64
FROM --platform=${MISE_PLATFORM} jdxcode/mise AS mise
FROM silex/emacs:${EMACS_VERSION}-ci
COPY --from=mise /usr/local/bin/mise /usr/local/bin/mise
