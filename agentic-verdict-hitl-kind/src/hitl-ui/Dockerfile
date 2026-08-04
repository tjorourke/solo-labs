FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/hitl-ui .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/hitl-ui /hitl-ui
EXPOSE 8080
ENTRYPOINT ["/hitl-ui"]
