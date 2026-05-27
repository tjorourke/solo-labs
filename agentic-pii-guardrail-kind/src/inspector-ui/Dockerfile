FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/inspector-ui .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/inspector-ui /inspector-ui
EXPOSE 8080
ENTRYPOINT ["/inspector-ui"]
