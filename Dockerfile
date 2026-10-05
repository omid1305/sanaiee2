FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    gettext \
    jq \
    openssl \
    coreutils \
    dos2unix

WORKDIR /usr/local/x-ui

RUN mkdir -p /usr/local/x-ui /var/log/x-ui /etc/nginx/inbounds

# 3x-ui latest release
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
        x86_64) XUI_ARCH="amd64" ;; \
        aarch64) XUI_ARCH="arm64" ;; \
        armv7l) XUI_ARCH="armv7" ;; \
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    curl -fL "https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${XUI_ARCH}.tar.gz" \
      -o /tmp/x-ui.tar.gz; \
    tar -xzf /tmp/x-ui.tar.gz -C /usr/local/; \
    rm -f /tmp/x-ui.tar.gz

COPY config.json /etc/x-ui/config.json
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY panel-bootstrap.sh /panel-bootstrap.sh
COPY start.sh /start.sh
COPY dynamic-nginx.sh /dynamic-nginx.sh

RUN chmod +x \
    /start.sh \
    /panel-bootstrap.sh \
    /dynamic-nginx.sh \
    /usr/local/x-ui/x-ui \
    2>/dev/null || true

RUN dos2unix \
    /start.sh \
    /panel-bootstrap.sh \
    /dynamic-nginx.sh \
    2>/dev/null || true

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3000/health || exit 1

CMD ["/start.sh"]