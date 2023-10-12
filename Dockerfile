FROM node:alpine

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install

COPY . .

EXPOSE 3001

CMD DB_HOST=<mongodb_host_value> DB_PORT=<mongodb_port_value> DB_NAME=<mongodb_name_value> DB_USER=<mongodb_user_value> DB_PASS=<mongodb_pass_value> node index.js