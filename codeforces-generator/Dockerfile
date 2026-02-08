FROM golang:1.25-alpine AS builder

ARG GOPROXY=direct
ARG GOSUMDB=off
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}
WORKDIR /app

RUN apk add --no-cache git
ENV GOTOOLCHAIN=local
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o generator

FROM alpine:3.20 AS runtime
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/generator /app/generator
ENTRYPOINT ["/app/generator"]
