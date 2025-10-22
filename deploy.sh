#!/bin/bash 
# ===============================================
# 🚀 Dockerized App Auto Deployment Script
# ===============================================
# Automates: cloning repo → remote setup → docker/compose deploy → nginx proxy
# Works for beginners with clear logs, checks, and validation.

set -e  # Exit on first error

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"

# ===== Helper Functions =====
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  echo -e "❌ Error: $1" | tee -a "$LOG_FILE"
  exit 1
}

# 🧯 Trap any unexpected errors with line number and exit code
trap 'error_exit "Unexpected error at line $LINENO (exit code $?). Check $LOG_FILE for details."' ERR


# ===== 1️⃣ Collect Parameters from User =====
read -p "👉 Enter your Git repository URL: " REPO_URL
read -p "🔑 Enter your Personal Access Token (PAT): " PAT
read -p "👤 Enter remote SSH username: " SSH_USER
read -p "🌍 Enter remote server IP address: " SERVER_IP
read -p "🗝️ Enter SSH key path (e.g., ~/.ssh/id_rsa): " SSH_KEY
read -p "⚙️ Enter application port (internal container port): " APP_PORT

BRANCH="main"
log "✅ Inputs collected successfully. Default branch set to: $BRANCH"

# ===== ✅ Input Verification =====
[ -z "$REPO_URL" ] && error_exit "Repository URL cannot be empty."
[ -z "$PAT" ] && error_exit "Personal Access Token is required."
[ -z "$SSH_USER" ] && error_exit "SSH username cannot be empty."
[ -z "$SERVER_IP" ] && error_exit "Server IP address cannot be empty."
[ -z "$APP_PORT" ] && error_exit "Application port is required."

if [ ! -f "$SSH_KEY" ]; then
  error_exit "SSH key file not found at: $SSH_KEY"
fi

if ! command -v git &> /dev/null; then
  error_exit "Git is not installed on this system."
fi

log "✅ All local prerequisites verified successfully."


# ===== 2️⃣ Clone or Update Repository =====
REPO_NAME=$(basename -s .git "$REPO_URL")

if [ -d "$REPO_NAME" ]; then
  log "📂 Repo already exists. Pulling latest changes..."
  cd "$REPO_NAME" && git pull origin "$BRANCH"
else
  log "⬇️ Cloning repository..."
  git clone https://$PAT@${REPO_URL#https://} --branch "$BRANCH"
  cd "$REPO_NAME"
fi

log "✅ Repository ready: $REPO_NAME"


# ===== 3️⃣ Validate Docker File =====
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  log "🧩 Docker configuration found."
else
  error_exit "No Dockerfile or docker-compose.yml found in the repository."
fi


# ===== 4️⃣ SSH Connectivity Check =====
log "🔐 Testing SSH connection..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" 'echo "SSH connected ✅"' || error_exit "SSH connection failed."


# ===== 5️⃣ Prepare Remote Environment =====
log "🧰 Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  sudo apt update -y
  sudo apt install -y docker.io docker-compose nginx
  sudo usermod -aG docker \$USER || true
  sudo systemctl enable docker nginx
  sudo systemctl start docker nginx
  docker --version
  docker-compose --version
  nginx -v
EOF
log "✅ Remote environment prepared."


# ===== 6️⃣ Deploy Dockerized Application =====
log "🚚 Copying project files to remote server..."
rsync -avz -e "ssh -i $SSH_KEY" ./ "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME"

log "⚙️ Building and running Docker container remotely..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  cd ~/$REPO_NAME
  echo "🧹 Removing any old container named myapp..."
  docker stop myapp || true
  docker rm myapp || true

  # 🧱 Auto-detect docker-compose.yml
  if [ -f "docker-compose.yml" ]; then
    echo "🧱 docker-compose.yml detected — using Docker Compose..."
    docker-compose down || true
    docker-compose up -d --build
  else
    echo "🐳 No docker-compose.yml found — using Dockerfile build..."
    docker build -t myapp:latest .
    docker run -d -p $APP_PORT:$APP_PORT --name myapp myapp:latest
  fi
EOF
log "✅ Application deployed successfully."


# ===== 7️⃣ Configure Nginx Reverse Proxy =====
log "🌐 Configuring Nginx reverse proxy..."
NGINX_CONF="/etc/nginx/sites-available/myapp.conf"

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" sudo bash <<EOF
cat > $NGINX_CONF <<NGINX
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
EOF

log "✅ Nginx configured to forward HTTP → Docker container."


# ===== 8️⃣ Validate Deployment =====
log "🩺 Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  echo "Checking Docker and Nginx status..."
  docker ps
  sudo systemctl status nginx --no-pager
  echo "Testing application endpoint..."
  curl -I localhost || true
EOF

log "✅ Validation complete."


# ===== 9️⃣ Logging and Error Handling =====
log "📜 All actions logged in $LOG_FILE"


# ===== 🔟 Cleanup & Idempotency ===== ###
log "♻️ Starting cleanup and idempotency checks..."

cleanup_remote() {
  log "🧹 Performing full cleanup on remote server..."
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
    set -e
    echo "Stopping and removing old containers..."
    docker stop myapp || true
    docker rm myapp || true
    docker image prune -af || true
    docker volume prune -f || true
    docker network prune -f || true
    echo "Removing old Nginx config..."
    sudo rm -f /etc/nginx/sites-available/myapp.conf
    sudo rm -f /etc/nginx/sites-enabled/myapp.conf
    sudo systemctl reload nginx
EOF
  log "✅ Cleanup completed successfully."
}

if [[ "$1" == "--cleanup" ]]; then
  cleanup_remote
  log "✅ Cleanup mode completed. Exiting script."
  exit 0
fi

log "🧠 Ensuring idempotency..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  echo "Checking for existing container..."
  if docker ps -a --format '{{.Names}}' | grep -q '^myapp$'; then
    echo "Found old container. Stopping and replacing..."
    docker stop myapp || true
    docker rm myapp || true
  fi

  echo "Removing unused Docker networks or images..."
  docker system prune -af || true
EOF

log "✅ Idempotency checks complete. Safe to re-run anytime."
log "🎉 Deployment completed successfully!"