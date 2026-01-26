FROM golang:1.24-alpine AS build

ARG GOPROXY=direct
ARG GOSUMDB=off
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=${GOSUMDB}
WORKDIR /src

RUN apk add --no-cache git
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/ssh-service .

FROM alpine:3.19
WORKDIR /app
RUN adduser -D -H appuser && chown -R appuser /app
USER appuser
COPY --from=build /out/ssh-service /app/ssh-service
EXPOSE 8086
ENTRYPOINT ["/app/ssh-service"]
