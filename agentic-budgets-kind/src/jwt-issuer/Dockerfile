FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
# Indirect deps for k8s.io/client-go aren't enumerated in go.mod; resolve at
# build time.
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/jwt-issuer .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/jwt-issuer /jwt-issuer
EXPOSE 8080
ENTRYPOINT ["/jwt-issuer"]
