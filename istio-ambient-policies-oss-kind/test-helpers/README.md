# Test helper only

The lab page deploys and enrols Bookinfo with Flightbay's Deploy Bookinfo
wizard. Flightbay has no command-line install for it, so the unattended harness
(`scripts/quick.sh up`) cannot click through the wizard. `deploy-bookinfo.sh`
applies the same manifests instead.

`bookinfo/*.yaml` are copied unchanged from Flightbay v0.4.5,
`internal/ambient/demo/`. The script sets the namespace labels the wizard sets
(`istio.io/dataplane-mode=ambient`, then `istio.io/use-waypoint=bookinfo-waypoint`
once the waypoint is Programmed). It leaves out Flightbay's ownership labels.
