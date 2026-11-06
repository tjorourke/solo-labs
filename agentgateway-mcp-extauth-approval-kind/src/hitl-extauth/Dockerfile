FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
# go mod tidy populates go.sum + adds the indirect deps needed by go-control-plane
# (cncf/xds, etc.) which the project only requires transitively. We resolve them
# at build time so the source tree only carries the direct deps in go.mod.
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/extauth .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/extauth /extauth
EXPOSE 9001 8081
ENTRYPOINT ["/extauth"]
