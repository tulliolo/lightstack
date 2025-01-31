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

# Funzione per installare Node.js
install_nodejs() {
    log_info "Installazione Node.js 20.x..."
    
    # Rimuovi versioni precedenti di Node.js se presenti
    apt-get remove -y nodejs npm || true
    
    # Aggiungi il repository NodeSource per Node.js 20.x
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    
    # Installa Node.js
    apt-get install -y nodejs
    
    # Verifica le versioni
    log_info "Versione Node.js installata:"
    node --version
    npm --version
}

# Install system dependencies
install_dependencies() {
    log_info "Aggiornamento del sistema e installazione dipendenze..."
    
    # Aggiorna i repository
    apt-get update
    
    # Installa le dipendenze di sistema
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

    # Installa Node.js
    install_nodejs
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
    
    # Create and activate virtual environment
    cd ui/backend
    python3 -m venv venv
    source venv/bin/activate
    
    # Install requirements
    pip install --upgrade pip
    pip install -r requirements.txt
    
    # Create systemd service for backend
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
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable lightstack-backend
    systemctl start lightstack-backend
    
    cd ../..
}

# Build and setup frontend
setup_frontend() {
    log_info "Setting up frontend..."
    
    cd ui/frontend
    
    # Pulisci l'installazione npm se esiste
    rm -rf node_modules package-lock.json
    
    # Installa le dipendenze e costruisci
    npm cache clean --force
    npm install
    npm run build
    
    # Move built files to nginx directory
    mkdir -p /var/www/lightstack
    cp -r dist/* /var/www/lightstack/
    
    # Set correct permissions
    chown -R www-data:www-data /var/www/lightstack
    chmod -R 755 /var/www/lightstack
    
    cd ../..
}

# Setup nginx configuration
setup_nginx() {
    local DOMAIN=$1
    log_info "Setting up nginx configuration for $DOMAIN..."

    # Assicurati che la directory sites-available esista
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # Create nginx configuration
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
        proxy_connect_timeout 300;
        proxy_send_timeout    300;
        proxy_read_timeout    300;
    }
    
    location /api/ {
        proxy_pass http://backend/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 300;
        proxy_send_timeout    300;
        proxy_read_timeout    300;
    }
}
EOF

    # Enable site
    ln -sf /etc/nginx/sites-available/lightstack /etc/nginx/sites-enabled/
    
    # Remove default nginx site if exists
    rm -f /etc/nginx/sites-enabled/default
    
    # Test nginx configuration
    nginx -t
    
    # Reload nginx
    systemctl reload nginx || systemctl start nginx
}

# Setup SSL certificates
setup_ssl() {
    local DOMAIN=$1
    local EMAIL=$2
    log_info "Setting up SSL certificates..."
    
    # Install certbot nginx plugin if not already installed
    apt-get install -y python3-certbot-nginx
    
    # Generate certificates
    certbot certonly --nginx \
        --non-interactive --agree-tos \
        --email "$EMAIL" \
        --domains "$DOMAIN"
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
    
    # Check requirements
    check_requirements
    
    # Install dependencies
    install_dependencies
    
    # Get configuration input
    read -p "Domain for web interface (e.g., manager.yourdomain.com): " DOMAIN
    read -p "Email for SSL certificates: " EMAIL
    read -p "Admin username: " ADMIN_USER
    read -s -p "Admin password: " ADMIN_PASS
    echo
    
    # Stop existing services if running
    systemctl stop lightstack-backend 2>/dev/null || true
    
    # Generate configurations
    generate_env
    
    # Setup components
    setup_backend
    setup_frontend
    setup_ssl "$DOMAIN" "$EMAIL"
    setup_nginx "$DOMAIN"
    
    log_info "Installation completed successfully!"
    echo
    echo "Access at https://$DOMAIN:8443"
    echo "Username: $ADMIN_USER"
    echo
    log_info "Useful commands:"
    echo "- View backend logs: journalctl -u lightstack-backend -f"
    echo "- Restart backend: systemctl restart lightstack-backend"
    echo "- Check nginx status: systemctl status nginx"
}

# Error handling
trap 'echo -e "\n${RED}Error: Installation interrupted${NC}"; exit 1' ERR

# Start installation
main
