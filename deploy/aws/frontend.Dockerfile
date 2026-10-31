FROM node:24-alpine AS build
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
COPY deploy/aws/tsconfig.production.json ./tsconfig.aws.json
# Same-origin API; an empty value also overrides the tracked localhost .env.
ENV VITE_API_URL=""
ENV NODE_OPTIONS="--max-old-space-size=768"
RUN npx tsc -p tsconfig.aws.json && npx vite build

FROM nginx:stable-alpine
COPY deploy/aws/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
