FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /luma ./cmd/luma
FROM alpine:3.21
RUN adduser -D -u 10001 luma && mkdir -p /app/storage && chown luma:luma /app/storage
WORKDIR /app
COPY --from=build --chown=luma:luma /luma /app/luma
COPY --from=build --chown=luma:luma /src/migrations /app/migrations
# Normalize copied source permissions, then make runtime resources read-only to luma.
RUN chmod 0755 /app /app/luma \
    && find /app/migrations -type d -exec chmod 0755 {} + \
    && find /app/migrations -type f -exec chmod 0644 {} + \
    && chown -R root:root /app/luma /app/migrations
USER luma
EXPOSE 8080
CMD ["/app/luma"]
