FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY app/ ./
EXPOSE 8080
CMD ["node", ".output/server/index.mjs"]
