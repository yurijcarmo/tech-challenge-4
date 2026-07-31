# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH \
    go build -ldflags="-s -w" -o /out/evaluation-service .

FROM gcr.io/distroless/static-debian12

WORKDIR /app

COPY --from=builder /out/evaluation-service /app/evaluation-service

USER nonroot:nonroot

EXPOSE 8004

ENTRYPOINT ["/app/evaluation-service"]
