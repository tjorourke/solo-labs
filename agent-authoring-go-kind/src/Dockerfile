# Two stages: build with the Go toolchain, run on a static base with nothing else in it.
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sre-go .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /sre-go /sre-go
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/sre-go"]
