#!/usr/bin/env bash

set -e
cd "$(dirname "$0")"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Install system dependencies
install_dependencies() {
    log_info "Aggiornamento del sistema e installazione dipendenze..."

    apt-get update

    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        nginx \
        certbot \
        python3-certbot-nginx \
        curl \
        git \
        build-essential \
        openssl
}

# Install and setup nvm
install_nvm() {
    log_info "Installing NVM (Node Version Manager)..."

    if ! command -v nvm &> /dev/null; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.4/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    else
        log_info "NVM is already installed. Skipping..."
    fi
}

# Install Node.js using nvm
install_nodejs() {
    install_nvm

    # Ensure nvm is loaded
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Prompt for Node.js version
    read -p "Enter Node.js version to install (default: 20.9.0): " NODE_VERSION
    NODE_VERSION=${NODE_VERSION:-20.9.0}

    log_info "Installing Node.js $NODE_VERSION using nvm..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"

    log_info "Node.js version installed:"
    node --version
    npm --version
}

# Check system requirements
check_requirements() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Setup Python virtual environment and install backend
setup_backend() {
    log_info "Setting up backend..."

    cd ui/backend
    python3 -m venv venv
    source venv/bin/activate

    pip install --upgrade pip
    pip install -r requirements.txt

    cat > /etc/systemd/system/lightstack-backend.service << EOF
[Unit]
Description=Lightstack Backend
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8005
Restart=always
RestartSec=5
StartLimitInterval=500
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lightstack-backend
    systemctl start lightstack-backend

    cd ../..
}

# Build and setup frontend
setup_frontend() {
    log_info "Setting up frontend..."

    cd ui/frontend

    # Load nvm
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    # Use the selected Node.js version
    nvm use "$(node --version | sed 's/v//')"

    rm -rf node_modules package-lock.json
    npm cache clean --force
    npm install
    npm run build

    mkdir -p /var/www/lightstack
    cp -r dist/* /var/www/lightstack/

    chown -R www-data:www-data /var/www/lightstack
    chmod -R 755 /var/www/lightstack

    cd ../..
}

# Setup nginx configuration
setup_nginx() {
    local DOMAIN=$1
    log_info "Setting up nginx configuration for $DOMAIN..."

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > /etc/nginx/sites-available/lightstack << EOF
upstream backend {
    server 127.0.0.1:8005;
}

server {
    listen 8443 ssl;
    server_name ${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    root /var/www/lightstack;
    
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
    
    location /api/ {
        proxy_pass http://backend/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/lightstack /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl reload nginx || systemctl start nginx
}

# Setup SSL certificates
setup_ssl() {
    local DOMAIN=$1
    local EMAIL=$2
    log_info "Setting up SSL certificates..."

    apt-get install -y python3-certbot-nginx

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        log_info "SSL certificate already exists. Skipping renewal..."
    else
        certbot certonly --nginx --non-interactive --agree-tos --email "$EMAIL" --domains "$DOMAIN"
    fi
}

# Generate environment configuration
generate_env() {
    log_info "Generating environment configuration..."

    JWT_SECRET=$(openssl rand -hex 32)

    cat > ui/backend/.env << EOF
DOMAIN=$DOMAIN
JWT_SECRET_KEY=$JWT_SECRET
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
NODE_ENV=production
EOF

    chmod 600 ui/backend/.env
}

# Main script
main() {
    clear
    log_info "Installing Lightstack UI (Traditional Setup)"

    check_requirements
    install_dependencies
    install_nodejs

    read -p "Domain for web interface (e.g., manager.yourdomain.com): " DOMAIN
    read -p "Email for SSL certificates: " EMAIL
    read -p "Admin username: " ADMIN_USER
    read -s -p "Admin password: " ADMIN_PASS
    echo

    systemctl stop lightstack-backend 2>/dev/null || true

    generate_env
    setup_backend
    setup_frontend
    setup_ssl "$DOMAIN" "$EMAIL"
    setup_nginx "$DOMAIN"

    log_info "Installation completed successfully!"
    echo
    echo "Access at https://$DOMAIN:8443"
    echo "Username: $ADMIN_USER"
}

trap 'echo -e "\n${RED}Error: Installation interrupted${NC}"; exit 1' ERR
main

