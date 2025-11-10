#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Detect package manager
if command -v apt >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    INSTALL_CMD="sudo apt install -y"
    REMOVE_CMD="sudo apt remove --purge -y"
    AUTOREMOVE_CMD="sudo apt autoremove -y"
    UPDATE_CMD="sudo apt update -y"
    CHECK_APACHE_CMD="dpkg -l | grep -q apache2"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="sudo dnf install -y"
    REMOVE_CMD="sudo dnf remove -y"
    AUTOREMOVE_CMD="sudo dnf autoremove -y"
    UPDATE_CMD="sudo dnf update -y"
    CHECK_APACHE_CMD="rpm -qa | grep -q httpd"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    INSTALL_CMD="sudo yum install -y"
    REMOVE_CMD="sudo yum remove -y"
    AUTOREMOVE_CMD="sudo yum autoremove -y"
    UPDATE_CMD="sudo yum update -y"
    CHECK_APACHE_CMD="rpm -qa | grep -q httpd"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="sudo pacman -S --noconfirm"
    REMOVE_CMD="sudo pacman -Rns --noconfirm"
    AUTOREMOVE_CMD="sudo pacman -Rns --noconfirm $(pacman -Qtdq 2>/dev/null || true)"
    UPDATE_CMD="sudo pacman -Sy --noconfirm"
    CHECK_APACHE_CMD="pacman -Q apache >/dev/null 2>&1"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    INSTALL_CMD="sudo apk add"
    REMOVE_CMD="sudo apk del"
    AUTOREMOVE_CMD=":" # not needed for Alpine
    UPDATE_CMD="sudo apk update"
    CHECK_APACHE_CMD="apk info | grep -q apache2"
else
    echo -e "${RED}Unsupported Linux distribution. Please install Nginx manually.${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}      ONL Stack Installation Script${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}▶ Detected package manager:${NC} ${BOLD}${PKG_MANAGER}${NC}"
echo ""

echo -e "${BLUE}▶ Initializing git submodules...${NC}"
git submodule update --init --recursive

echo ""
echo -e "${BLUE}▶ Building Docker images...${NC}"
make build

echo ""
echo -e "${BLUE}▶ Checking for Apache2...${NC}"
if eval "$CHECK_APACHE_CMD"; then
    echo -e "${YELLOW}⚠ Apache2 is detected on this system.${NC}"
    read -p "Do you want to remove Apache2? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Removing Apache2...${NC}"
        sudo systemctl stop apache2 2>/dev/null || sudo systemctl stop httpd 2>/dev/null
        eval "$REMOVE_CMD apache2 || $REMOVE_CMD httpd"
        eval "$AUTOREMOVE_CMD"
        echo -e "${GREEN}✅ Apache2 removed successfully.${NC}"
    else
        echo -e "${YELLOW}⊘ Skipping Apache2 removal.${NC}"
    fi
else
    echo -e "${GREEN}✓ Apache2 not found.${NC}"
fi

echo ""
echo -e "${BLUE}▶ Installing Nginx...${NC}"
if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${YELLOW}Nginx not found. Installing...${NC}"
    eval "$UPDATE_CMD"
    eval "$INSTALL_CMD nginx"
    echo -e "${GREEN}✅ Nginx installed successfully.${NC}"
else
    echo -e "${GREEN}✓ Nginx is already installed.${NC}"
fi

echo ""
echo -e "${BLUE}▶ Ensuring nginx is enabled and running...${NC}"
sudo systemctl enable nginx 2>/dev/null || true
sudo systemctl start nginx 2>/dev/null || true

if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}✅ Nginx is running.${NC}"
else
    echo -e "${RED}❌ Nginx failed to start. Check logs with: sudo journalctl -u nginx${NC}"
fi

echo ""
echo -e "${BLUE}▶ Checking .env configuration...${NC}"
if [ -f .env ]; then
    echo -e "${YELLOW}⚠ .env file detected.${NC}"
    read -p "Did you update your .env keys (SSL, DOMAIN, etc.) before continuing? (y/N): " env_confirm
    if [[ ! "$env_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Please update your .env keys before starting installation (DOMAIN, FLEXIBLE, CERTS).${NC}"
        exit 1
    else
        echo -e "${GREEN}✓ .env keys confirmed as updated.${NC}"
    fi
else
    echo -e "${RED}❌ No .env file detected.${NC}"
    echo -e "${YELLOW}Please copy .env.example to .env and update it accordingly.${NC}"
    exit 1
fi

DOMAIN=$(grep '^DOMAIN=' .env | cut -d '=' -f2)
FLEXIBLE=$(grep '^FLEXIBLE=' .env | cut -d '=' -f2)
BANCHO_PORT=$(grep '^BANCHO_PORT=' .env | cut -d '=' -f2)
SHIINA_PORT=$(grep '^SHIINA_PORT=' .env | cut -d '=' -f2)
PMA_PORT=$(grep '^PMA_PORT=' .env | cut -d '=' -f2)
SSL_CERT_PATH=$(grep '^SSL_CERT_PATH=' .env | cut -d '=' -f2)
SSL_KEY_PATH=$(grep '^SSL_KEY_PATH=' .env | cut -d '=' -f2)

echo ""
echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  ${BLUE}Domain:${NC} ${BOLD}${DOMAIN}${NC}"
echo -e "  ${BLUE}Flexible SSL:${NC} ${BOLD}${FLEXIBLE}${NC}"
echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
echo ""

if [ "$FLEXIBLE" = "true" ]; then
    echo -e "${YELLOW}⚠ Flexible SSL is enabled. Skipping SSL certificate check.${NC}"
    NGINX_PORT=80
else
    echo -e "${BLUE}▶ Checking for SSL certificates...${NC}"
    if [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
        echo -e "${GREEN}✅ SSL certificates found.${NC}"
        NGINX_PORT="443 ssl"
    else
        echo -e "${RED}❌ SSL certificates not found at:${NC}"
        echo -e "   ${YELLOW}Cert: $SSL_CERT_PATH${NC}"
        echo -e "   ${YELLOW}Key: $SSL_KEY_PATH${NC}"
        echo -e "${RED}Please obtain valid SSL certificates for your domain before proceeding.${NC}"
        exit 1
    fi
fi

DATA_DIRECTORY=$(pwd)/.data
echo ""
echo -e "${BLUE}▶ Setting up data directory...${NC}"
echo -e "  ${BLUE}Files:${NC} ${DATA_DIRECTORY}"

NGINX_LOG_DIRECTORY="$DATA_DIRECTORY/nginx"
mkdir -p "$NGINX_LOG_DIRECTORY"
echo -e "  ${BLUE}Nginx logs:${NC} ${NGINX_LOG_DIRECTORY}"

# --- Auto-detect Nginx configuration path ---
if [ -d /etc/nginx/sites-available ]; then
    NGINX_CONF_DIR="/etc/nginx/sites-available"
elif [ -d /etc/nginx/conf.d ]; then
    NGINX_CONF_DIR="/etc/nginx/conf.d"
else
    NGINX_CONF_DIR="/etc/nginx"
fi

echo -e "  ${BLUE}Nginx config:${NC} ${NGINX_CONF_DIR}"
echo -e "  ${BLUE}Nginx port:${NC} ${NGINX_PORT}"

echo ""
echo -e "${BLUE}▶ Creating Nginx configuration...${NC}"
NGINX_CONF="${NGINX_CONF_DIR}/${DOMAIN}.conf"

# Remove old configuration if it exists
sudo rm -f "$NGINX_CONF"
sudo rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf"

if [ "$FLEXIBLE" = "true" ]; then
    # HTTP-only (no SSL)
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
# c[e4]?.ppy.sh is used for bancho
# osu.ppy.sh is used for /web, /api, etc.
# a.ppy.sh is used for osu! avatars

upstream server {
    server 127.0.0.1:${BANCHO_PORT};
}

upstream web {
    server 127.0.0.1:${SHIINA_PORT};
}

server {
	listen 80;
	server_name c.${DOMAIN} ce.${DOMAIN} c4.${DOMAIN} osu.${DOMAIN} b.${DOMAIN} api.${DOMAIN};
	client_max_body_size 20M;

    access_log ${NGINX_LOG_DIRECTORY}/bancho_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/bancho_error.log;

	location / {
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Real-IP  \$remote_addr;
		proxy_set_header Host \$http_host;
		add_header Access-Control-Allow-Origin *;
		proxy_redirect off;
		proxy_pass http://server;
	}
}

server {
	listen 80;
	server_name ${DOMAIN};
	client_max_body_size 20M;

    access_log ${NGINX_LOG_DIRECTORY}/shiina_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/shiina_error.log;

	location / {
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Real-IP  \$remote_addr;
		proxy_set_header Host \$http_host;
		add_header Access-Control-Allow-Origin *;
		proxy_redirect off;
		proxy_pass http://web;
	}
}

server {
	listen 80;
	server_name assets.${DOMAIN};

    access_log ${NGINX_LOG_DIRECTORY}/assets_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/assets_error.log;

	location / {
		default_type image/png;
		root ${DATA_DIRECTORY}/bancho/assets;
	}
}

server {
	listen 80;
	server_name a.${DOMAIN};

    access_log ${NGINX_LOG_DIRECTORY}/avatars_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/avatars_error.log;

	location / {
		root ${DATA_DIRECTORY}/bancho/avatars;
		try_files \$uri \$uri.png \$uri.jpg \$uri.gif \$uri.jpeg \$uri.jfif /default.jpg = 404;
	}
}
EOF
else
    # SSL configuration
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
# c[e4]?.ppy.sh is used for bancho
# osu.ppy.sh is used for /web, /api, etc.
# a.ppy.sh is used for osu! avatars

upstream server {
    server 127.0.0.1:${BANCHO_PORT};
}

upstream web {
    server 127.0.0.1:${SHIINA_PORT};
}

server {
	listen 443 ssl;
	server_name c.${DOMAIN} ce.${DOMAIN} c4.${DOMAIN} osu.${DOMAIN} b.${DOMAIN} api.${DOMAIN};
	client_max_body_size 20M;

	ssl_certificate     ${SSL_CERT_PATH};
	ssl_certificate_key ${SSL_KEY_PATH};
	ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:@SECLEVEL=1";

    access_log ${NGINX_LOG_DIRECTORY}/bancho_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/bancho_error.log;

	location / {
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Real-IP  \$remote_addr;
		proxy_set_header Host \$http_host;
		add_header Access-Control-Allow-Origin *;
		proxy_redirect off;
		proxy_pass http://server;
	}
}

server {
	listen 443 ssl;
	server_name ${DOMAIN};
	client_max_body_size 20M;

	ssl_certificate     ${SSL_CERT_PATH};
	ssl_certificate_key ${SSL_KEY_PATH};
	ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:@SECLEVEL=1";

    access_log ${NGINX_LOG_DIRECTORY}/shiina_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/shiina_error.log;

	location / {
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Real-IP  \$remote_addr;
		proxy_set_header Host \$http_host;
		add_header Access-Control-Allow-Origin *;
		proxy_redirect off;
		proxy_pass http://web;
	}
}

server {
	listen 443 ssl;
	server_name assets.${DOMAIN};

	ssl_certificate     ${SSL_CERT_PATH};
	ssl_certificate_key ${SSL_KEY_PATH};
	ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:@SECLEVEL=1";

    access_log ${NGINX_LOG_DIRECTORY}/assets_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/assets_error.log;

	location / {
		default_type image/png;
		root ${DATA_DIRECTORY}/bancho/assets;
	}
}

server {
	listen 443 ssl;
	server_name a.${DOMAIN};

	ssl_certificate     ${SSL_CERT_PATH};
	ssl_certificate_key ${SSL_KEY_PATH};
	ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:@SECLEVEL=1";

    access_log ${NGINX_LOG_DIRECTORY}/avatars_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/avatars_error.log;

	location / {
		root ${DATA_DIRECTORY}/bancho/avatars;
		try_files \$uri \$uri.png \$uri.jpg \$uri.gif \$uri.jpeg \$uri.jfif /default.jpg = 404;
	}
}
EOF
fi

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
echo -e "${GREEN}✅ Main Nginx configuration created.${NC}"

echo ""
echo -e "${BLUE}▶ phpMyAdmin setup...${NC}"
# Ask if user wants to have phpmmyadmin installed   
read -p "Do you want to install phpMyAdmin? (y/N): " pma_confirm
if [[ "$pma_confirm" =~ ^[Yy]$ ]]; then
    cp scripts/install/docker-compose.override.yml docker-compose.override.yml
    echo -e "${GREEN}✅ phpMyAdmin Docker configuration added.${NC}"

    read -p "What should be the name of your subdomain for phpMyAdmin? " pma_subdomain

    NGINX_CONF="${NGINX_CONF_DIR}/${pma_subdomain}.${DOMAIN}.conf"

    sudo rm -f "$NGINX_CONF"
    sudo rm -f "/etc/nginx/sites-enabled/${pma_subdomain}.${DOMAIN}.conf"

    if [ "$FLEXIBLE" = "true" ]; then
        # HTTP-only (no SSL)
        sudo tee "$NGINX_CONF" > /dev/null <<EOF
upstream pma {
    server 127.0.0.1:${PMA_PORT};
}

server {
    listen 80;
    server_name ${pma_subdomain}.${DOMAIN};
    client_max_body_size 500M;

    access_log ${NGINX_LOG_DIRECTORY}/pma_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/pma_error.log;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header Host \$http_host;
        proxy_redirect off;
        proxy_pass http://pma;
    }
}
EOF
    else
        # SSL configuration
        sudo tee "$NGINX_CONF" > /dev/null <<EOF
upstream pma {
    server 127.0.0.1:${PMA_PORT};
}

server {
    listen 443 ssl;
    server_name ${pma_subdomain}.${DOMAIN};
    client_max_body_size 500M;
    ssl_certificate     ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_KEY_PATH};
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH:@SECLEVEL=1";

    access_log ${NGINX_LOG_DIRECTORY}/pma_access.log;
    error_log ${NGINX_LOG_DIRECTORY}/pma_error.log;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_set_header Host \$http_host;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PMA_PORT};
    }
}
EOF
    fi
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    echo -e "${GREEN}✅ phpMyAdmin Nginx configuration created.${NC}"
else
    echo -e "${YELLOW}⊘ Skipping phpMyAdmin installation.${NC}"
fi

echo ""
echo -e "${BLUE}▶ Setting up log rotation for nginx logs...${NC}"
LOGROTATE_CONF="/etc/logrotate.d/onl-nginx"
sudo tee "$LOGROTATE_CONF" > /dev/null <<EOF
${NGINX_LOG_DIRECTORY}/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    dateext
    dateformat -%Y%m%d
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 \$(cat /var/run/nginx.pid)
        fi
    endscript
}
EOF
echo -e "${GREEN}✅ Log rotation configured. Logs will be rotated daily and kept for 30 days.${NC}"

echo ""
echo -e "${BLUE}▶ Testing Nginx configuration...${NC}"
if sudo nginx -t; then
    sudo systemctl reload nginx
    echo -e "${GREEN}✅ Nginx reloaded successfully.${NC}"
else
    echo -e "${RED}❌ Nginx configuration test failed.${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}▶ Docker security configuration...${NC}"
CONFIG_FILE="/etc/docker/daemon.json"
read -p "Do you want to secure docker by disabling exposing ports over iptables? (y/N): " iptables_confirm

if [[ "$iptables_confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Configuring Docker to disable iptables exposure...${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        sudo jq '. + {"iptables": true}' "$CONFIG_FILE" > /tmp/daemon.json.tmp && sudo mv /tmp/daemon.json.tmp "$CONFIG_FILE"
    else
        echo '{ "iptables": true }' | sudo tee "$CONFIG_FILE" >/dev/null
    fi
    echo -e "${YELLOW}Restarting Docker service...${NC}"
    sudo systemctl restart docker
    echo -e "${GREEN}✅ Docker configured to disable iptables exposure.${NC}"
else
    echo -e "${YELLOW}⊘ Skipping Docker iptables configuration.${NC}"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}✅ Installation completed successfully!${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Next step:${NC}"
echo -e "  Start the stack: ${CYAN}make run${NC}"
echo ""
