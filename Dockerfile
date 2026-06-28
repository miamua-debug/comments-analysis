FROM node:18-slim

# Install Python for data fetching scripts
RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Node deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Install Python deps
COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy app
COPY . .

# Docker uses python3 binary
ENV PYTHON_BIN=python3

EXPOSE 9876
CMD ["node", "server.js"]
