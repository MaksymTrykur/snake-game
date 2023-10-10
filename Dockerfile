FROM node:alpine

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

ENV DB_HOST=mongodb_host
ENV DB_PORT=27017
ENV DB_NAME=snake_game

EXPOSE 3001

CMD [ "node", "index.js" ]