FROM node:18-slim

# Install Python for data fetching scripts
RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Node deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Install Python deps (use venv to avoid PEP 668 restriction)
COPY requirements.txt ./
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt
ENV PATH="/opt/venv/bin:$PATH"

# Copy app
COPY . .

# Use venv python
ENV PYTHON_BIN=/opt/venv/bin/python

EXPOSE 9876
CMD ["node", "server.js"]
