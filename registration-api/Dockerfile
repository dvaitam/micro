FROM golang:1.24-alpine

WORKDIR /app

RUN go mod init registration-api

RUN go get github.com/segmentio/kafka-go
RUN go get github.com/go-sql-driver/mysql
RUN go get github.com/google/uuid
COPY . .
RUN go build -o app .

EXPOSE 8080

CMD ["./app"]
