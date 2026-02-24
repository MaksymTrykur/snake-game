FROM node:24-alpine

WORKDIR /app

# Install production dependencies from lockfile
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy application source
COPY . .

ENV NODE_ENV=production

EXPOSE 3001

CMD ["node", "index.js"]
