FROM golang:1.24-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /luma ./cmd/luma

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
# Fail the image build if the runtime user cannot read any migration.
RUN set -eu; test -x /app/luma; test -r /app/migrations/001_init.sql; \
    for file in /app/migrations/*.sql; do test -r "$file"; done
EXPOSE 8080
CMD ["/app/luma"]
