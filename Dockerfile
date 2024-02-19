FROM node:18-alpine
WORKDIR '/app'
COPY package*.json ./
RUN npm install
    && apk update \
    && apk --no-cache add curl \
    && apk --no-cache add unzip \
    && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install
    && apk add --update docker openrc.
COPY index.js ./
EXPOSE 5000
CMD ["node", "index.js"]
