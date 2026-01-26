FROM golang:1.24-alpine

ARG GOPROXY=direct
ARG GOSUMDB=off
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}

WORKDIR /app

RUN apk add --no-cache git

RUN go mod init registration-api

RUN go get github.com/segmentio/kafka-go
RUN go get github.com/go-sql-driver/mysql
RUN go get github.com/google/uuid
RUN go get github.com/redis/go-redis/v9
COPY . .
RUN go build -o app .

EXPOSE 8080

CMD ["./app"]
