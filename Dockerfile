FROM node:14-alpine

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

EXPOSE 3001

ENV DB_HOST=mongo
ENV DB_PORT=27017
ENV DB_USER=root
ENV DB_PASS=example
ENV DB_NAME=test

CMD [ "node", "index.js" ]