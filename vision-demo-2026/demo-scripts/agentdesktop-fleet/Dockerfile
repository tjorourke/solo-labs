# A simulated corporate workstation: the real agentdesktop device binary, with
# a scripted sign-in standing in for the browser a laptop would open.
FROM debian:stable-slim
# The release binary is one executable carrying both the daemon and the desktop
# window, so it links GTK even when only `daemon` is used. These are the
# runtime libraries that needs, not a desktop session.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl jq ca-certificates libgtk-3-0 libayatana-appindicator3-1 libwebkit2gtk-4.1-0 \
 && rm -rf /var/lib/apt/lists/*
COPY agentdesktop-linux-arm64 /usr/local/bin/agentdesktop
COPY enrol.sh /usr/local/bin/enrol.sh
RUN chmod +x /usr/local/bin/agentdesktop /usr/local/bin/enrol.sh
# A daemon running as root will not serve its socket to everyone: it requires
# an `agentdesktop` group naming the users allowed to talk to it.
RUN groupadd agentdesktop && usermod -aG agentdesktop root
ENTRYPOINT ["/usr/local/bin/enrol.sh"]
