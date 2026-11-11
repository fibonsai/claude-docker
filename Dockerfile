FROM alpine:latest

RUN adduser claude || true
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" >> /etc/apk/repositories && apk update
RUN apk add --no-cache ca-certificates curl libc6-compat tzdata bash libgcc libstdc++ ripgrep

USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash 
ENV PATH=${PATH}:~claude/.local/bin

WORKDIR /workspace
