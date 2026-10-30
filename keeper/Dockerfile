FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY src ./src
# DRY_RUN defaults true. Pass KEEPER_PRIVATE_KEY as a runtime secret for real sends; never bake it into the image.
CMD ["node", "src/index.mjs"]
