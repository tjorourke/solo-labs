# vLLM Semantic Router configuration wizard — a static site, so this is nginx and
# five files. There is no backend and no build step: the wizard computes the config,
# the checks and the YAML in the browser.
#
# Build from the parent directory, so the wizard's files are in context:
#   docker build -f selfhost/Dockerfile -t vsr-config-wizard .
FROM nginx:1.27-alpine

# standalone.html carries its own chrome. index.html is the one that expects the
# website's stylesheet around it, so it is deliberately not copied here.
COPY standalone.html /usr/share/nginx/html/index.html
COPY vsr-core.js     /usr/share/nginx/html/vsr-core.js
COPY presets.js      /usr/share/nginx/html/presets.js
COPY wizard.js       /usr/share/nginx/html/wizard.js
COPY wizard.css      /usr/share/nginx/html/wizard.css

COPY selfhost/nginx.conf /etc/nginx/conf.d/default.conf

# Runs unprivileged on 8080. The stock nginx image listens on 80 as root, which a
# restricted PodSecurity namespace will refuse, and this is going into clusters.
# nginx writes a pid file and temp files. The temp paths move to /tmp in
# nginx.conf; the pid moves here. After this the only writable path the container
# needs is /tmp, so the root filesystem can be mounted read-only.
RUN sed -i 's|^user  nginx;|# user directive dropped: runs as an arbitrary uid|' /etc/nginx/nginx.conf \
 && sed -i -E 's|^pid[[:space:]]+.*;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf \
 && grep -q '^pid /tmp/nginx.pid;' /etc/nginx/nginx.conf \
 && chgrp -R 0 /usr/share/nginx/html \
 && chmod -R g=u /usr/share/nginx/html

USER 101
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=3s \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
