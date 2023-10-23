FROM node:16-alpine
ENV DB_HOST=localhost
ENV DB_PORT=27017
ENV DB_NAME=snake-game
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3001
CMD ["node", "index.js"]