FROM golang:1.22-alpine AS builder
WORKDIR /app
ENV GOTOOLCHAIN=auto
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o worker

FROM golang:1.22-alpine AS runtime
RUN apk add --no-cache g++ python3 rust
WORKDIR /app
COPY --from=builder /app/worker /app/worker
ENTRYPOINT ["/app/worker"]
