FROM golang:1.24-alpine

ARG GOPROXY=direct
ARG GOSUMDB=off
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}

WORKDIR /app

RUN apk add --no-cache git
RUN go mod init email-worker
RUN go get github.com/segmentio/kafka-go
RUN go get github.com/mailgun/mailgun-go/v4
RUN go get github.com/go-sql-driver/mysql

COPY . .
RUN go build -o worker .

CMD ["./worker"]
