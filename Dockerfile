FROM node:18-slim
# v3 — Railway Dockerfile build

# Install Python for data fetching scripts
RUN apt-get update && apt-get install -y python3 python3-pip python3-venv && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Node deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Install Python deps in venv
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir requests apify-client
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHON_BIN=/opt/venv/bin/python

# Copy app
COPY . .

EXPOSE 9876
CMD ["node", "server.js"]
