FROM golang:1.22-alpine AS builder
WORKDIR /app
ENV GOTOOLCHAIN=auto
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o api

FROM gcr.io/distroless/base-debian12
WORKDIR /app
COPY --from=builder /app/api /app/api
ENV PORT=8082
EXPOSE 8082
ENTRYPOINT ["/app/api"]
