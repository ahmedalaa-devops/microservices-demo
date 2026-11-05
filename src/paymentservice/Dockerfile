# syntax=docker/dockerfile:1

ARG BUILDPLATFORM=linux/amd64

FROM --platform=$BUILDPLATFORM node:24.20.0-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS builder

WORKDIR /usr/src/app

# Build dependencies for native Node.js modules
RUN apk add --no-cache python3 make g++

# Copy dependency manifests first for better layer caching
COPY package.json package-lock.json ./

# Install exact locked production dependencies
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

FROM node:24.20.0-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf

WORKDIR /usr/src/app

COPY --from=builder /usr/src/app/node_modules ./node_modules
COPY . .

EXPOSE 50051

ENTRYPOINT ["node", "index.js"]
