FROM alpine:latest

RUN adduser -D claude \
 && echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories \
 && apk add --no-cache ca-certificates curl libc6-compat tzdata bash libgcc libstdc++ ripgrep \
 && mkdir -p /sandbox \
 && chown claude:claude /sandbox

USER claude
ENV HOME=/home/claude
ENV PATH="/home/claude/.local/bin:${PATH}"
RUN curl -fsSL https://claude.ai/install.sh | bash

# OpenShell uses /sandbox as its managed workspace volume. Standalone Docker
# users can override the working directory with `-w /workspace`.
WORKDIR /sandbox
