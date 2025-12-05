FROM golang:1.21-alpine AS builder

WORKDIR /build

# Install dependencies
RUN apk add --no-cache git make

# Copy go mod files
COPY go.mod go.sum* ./
RUN go mod download

# Copy source
COPY main.go ./

# Build
RUN go build -o sync-rules-dashboards main.go

# Runtime image
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /build/sync-rules-dashboards .

ENTRYPOINT ["./sync-rules-dashboards"]

