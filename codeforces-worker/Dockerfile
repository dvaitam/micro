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
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o worker

FROM golang:1.22-alpine AS runtime
# Toolchains needed for supported languages: C/C++, Python, Rust, Java
RUN apk add --no-cache g++ gcc python3 rust openjdk17-jdk
WORKDIR /app
COPY --from=builder /app/worker /app/worker
ENTRYPOINT ["/app/worker"]
