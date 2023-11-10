FROM node:14-alpine

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install

COPY . .

ENV DB_HOST=mongodb-service
ENV DB_PORT=27017
ENV DB_NAME=snakegame
ENV DB_USER=root
ENV DB_PASS=root

EXPOSE 3001

CMD [ "node", "index.js" ]