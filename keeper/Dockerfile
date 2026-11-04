FROM node:22-alpine
WORKDIR /app
COPY keeper/package.json keeper/package-lock.json* ./
RUN npm install --omit=dev
COPY keeper/src ./src
COPY deployments ./deployments
CMD ["node", "src/index.mjs"]
