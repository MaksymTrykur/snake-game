FROM node:14-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3001
CMD [ "node", "index.js" ]
ENV DB_HOST=mongodb
ENV DB_PORT=27017
ENV DB_NAME=snake_game
ENV DB_USER=
ENV DB_PASS=