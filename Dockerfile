# Use a lightweight version of Node.js
FROM node:16-alpine

# Set the working directory
WORKDIR /usr/src/app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy the rest of the app
COPY . .

# Expose app on port
EXPOSE 3001

# Add environment variables
ENV DB_HOST=mongodb
ENV DB_PORT=27017
ENV DB_NAME=snakegame
ENV DB_USER=root
ENV DB_PASS=root

# Start the app
CMD [ "node", "index.js" ]