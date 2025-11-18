FROM golang:1.24-alpine

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -o rtc-service .

EXPOSE 8085

CMD ["./rtc-service"]
