FROM node:16-alpine

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

ENV DB_HOST=mongodb_host
ENV DB_PORT=27017
ENV DB_NAME=test
ENV DB_USER=myUser
ENV DB_PASS=myPassword

EXPOSE 3001

CMD ["node", "index.js"]