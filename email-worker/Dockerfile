FROM golang:1.24-alpine

WORKDIR /app
RUN go mod init email-worker
RUN go get github.com/segmentio/kafka-go
RUN go get github.com/mailgun/mailgun-go/v4
RUN go get github.com/go-sql-driver/mysql

COPY . .
RUN go build -o worker .

CMD ["./worker"]
