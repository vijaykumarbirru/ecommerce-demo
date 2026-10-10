FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# go.sum is resolved at build time so the repo only carries go.mod.
RUN go mod tidy && CGO_ENABLED=0 go build -o /api-gateway .

FROM alpine:3.20
COPY --from=build /api-gateway /api-gateway
EXPOSE 8000
ENTRYPOINT ["/api-gateway"]
