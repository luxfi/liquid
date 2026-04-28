# syntax=docker/dockerfile:1.7
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml* yarn.lock* package-lock.json* ./
RUN if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then yarn install --frozen-lockfile; \
    else npm ci; fi
COPY . .
RUN if [ -f pnpm-lock.yaml ]; then pnpm build && pnpm index; \
    elif [ -f yarn.lock ]; then yarn build && yarn index; \
    else npm run build && npm run index; fi

FROM ghcr.io/hanzoai/spa
COPY --from=build /app/build /public
