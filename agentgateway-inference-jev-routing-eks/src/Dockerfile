FROM golang:1.24.13-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go profile.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /adapter .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /adapter /adapter
USER 65532:65532
ENTRYPOINT ["/adapter"]
