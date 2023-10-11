FROM node:16

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

ENV PORT=3001
ENV DB_HOST='mongodb_host'
ENV DB_PORT=27017
ENV DB_NAME='database'
ENV DB_USER='username'
ENV DB_PASS='password'

EXPOSE $PORT

CMD [ "node", "index.js" ]