#!/usr/bin/env bash
# port-forward.sh — the ingress gateway is already reachable on the host via the
# kind port map (localhost:18080 → NodePort 30080). This helper just prints the
# curl you want; no forward is actually needed.
echo "Ingress (Host: petstore.local) is mapped to http://localhost:18080/"
echo
echo "  curl -H 'Host: petstore.local' http://localhost:18080/"
echo "  curl -H 'Host: petstore.local' -X DELETE http://localhost:18080/   # 403 once ingress-use-waypoint is set"
