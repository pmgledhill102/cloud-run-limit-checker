# Stage 1: build
FROM golang:1.23-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o checker .

# Stage 2: runtime
FROM gcr.io/distroless/static-debian12
COPY --from=build /app/checker /checker
ENTRYPOINT ["/checker"]
