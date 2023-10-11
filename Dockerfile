FROM node:14

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install

COPY . .

EXPOSE 3001

ENV DB_HOST=db_host
ENV DB_PORT=db_port
ENV DB_NAME=db_name
ENV DB_USER=db_user
ENV DB_PASS=db_pass

CMD [ "node", "index.js" ]