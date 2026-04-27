FROM node:20-alpine

# claude CLI a besoin de bash et curl pour son installer + healthcheck
RUN apk add --no-cache bash curl

# Install claude CLI globalement dans le container
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app
COPY proxy.js .

# Volume pour persister les credentials OAuth entre redemarrages
# (claude auth login ecrit dans /root/.claude/.credentials.json)
VOLUME ["/root/.claude"]

EXPOSE 18801

CMD ["node", "proxy.js"]
