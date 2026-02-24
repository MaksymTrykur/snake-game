FROM node:24-alpine

WORKDIR /app

# Install only production dependencies (reproducible via lockfile)
COPY package.json package-lock.json ./
# NOTE: The lockfile in this repo may not be in perfect sync with package.json.
# Use `npm install` (not `npm ci`) to be more forgiving while still installing
# production-only deps.
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

# Copy application source
COPY index.js ./index.js
COPY public ./public

ENV NODE_ENV=production
# Optional at runtime: DB_CONN (MongoDB connection string)

EXPOSE 3001

CMD ["node", "index.js"]
