FROM golang:1.24-alpine

ARG GOPROXY=direct
ARG GOSUMDB=off
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}

WORKDIR /app

RUN apk add --no-cache git

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -o rtc-service .

EXPOSE 8085

CMD ["./rtc-service"]
