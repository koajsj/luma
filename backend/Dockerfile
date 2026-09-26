FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /luma ./cmd/luma
FROM alpine:3.21
RUN adduser -D -u 10001 luma && mkdir -p /app/storage && chown luma:luma /app/storage
WORKDIR /app
COPY --from=build /luma /app/luma
COPY --from=build /src/migrations /app/migrations
USER luma
EXPOSE 8080
CMD ["/app/luma"]
