FROM node:16-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
ENV DB_HOST=mongo
ENV DB_PORT=27017
ENV DB_NAME=snake_game
ENV DB_USER=root
ENV DB_PASS=example
EXPOSE 3001
CMD [ "node", "index.js" ]