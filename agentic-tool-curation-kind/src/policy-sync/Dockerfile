FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags '-s -w' -o /out/policy-sync .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/policy-sync /policy-sync
EXPOSE 8080
ENTRYPOINT ["/policy-sync"]
