#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

echo -e "${GREEN}Detected package manager: ${PKG_MANAGER}${NC}"
echo -e "${GREEN}Starting onl stack installation...${NC}"

echo -e "${GREEN}Initializing git submodules...${NC}"
git submodule update --init --recursive

echo -e "${GREEN}Building Docker images...${NC}"
make build

echo -e "${GREEN}Checking for Apache2...${NC}"
if eval "$CHECK_APACHE_CMD"; then
    echo -e "${YELLOW}Apache2 is detected on this system.${NC}"
    read -p "Do you want to remove Apache2? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Removing Apache2...${NC}"
        sudo systemctl stop apache2 2>/dev/null || sudo systemctl stop httpd 2>/dev/null
        eval "$REMOVE_CMD apache2 || $REMOVE_CMD httpd"
        eval "$AUTOREMOVE_CMD"
        echo -e "${GREEN}Apache2 removed successfully.${NC}"
    else
        echo -e "${YELLOW}Skipping Apache2 removal.${NC}"
    fi
else
    echo -e "${GREEN}Apache2 not found.${NC}"
fi

echo -e "${GREEN}Installing Nginx...${NC}"
if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${RED}Nginx not found. Installing...${NC}"
    eval "$UPDATE_CMD"
    eval "$INSTALL_CMD nginx"
    echo -e "${GREEN}Nginx installed successfully.${NC}"
else
    echo -e "${GREEN}Nginx is already installed.${NC}"
fi

echo -e "${GREEN}Ensuring nginx is enabled and running...${NC}"
sudo systemctl enable nginx 2>/dev/null || true
sudo systemctl start nginx 2>/dev/null || true

if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}✅ Nginx is running.${NC}"
else
    echo -e "${RED}❌ Nginx failed to start. Check logs with: sudo journalctl -u nginx${NC}"
fi

if [ -f .env ]; then
    echo -e "${YELLOW}.env file detected.${NC}"
    read -p "Did you update your .env keys (SSL, DOMAIN, etc.) before continuing? (y/N): " env_confirm
    if [[ ! "$env_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Please make sure your .env keys are up to date before starting installation (DOMAIN, FLEXIBLE, CERTS).${NC}"
        exit 1
    else
        echo -e "${GREEN}.env keys confirmed as updated.${NC}"
    fi
else
    echo -e "${YELLOW}No .env file detected. Copy .env.example to .env and update it accordingly.${NC}"
    exit 1
fi

DOMAIN=$(grep '^DOMAIN=' .env | cut -d '=' -f2)
FLEXIBLE=$(grep '^FLEXIBLE=' .env | cut -d '=' -f2)
BANCHO_PORT=$(grep '^BANCHO_PORT=' .env | cut -d '=' -f2)
SHIINA_PORT=$(grep '^SHIINA_PORT=' .env | cut -d '=' -f2)
SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo -e "${GREEN}Your DOMAIN is set to: ${DOMAIN}${NC}"
echo -e "${GREEN}Your FLEXIBLE SSL setting is set to: ${FLEXIBLE}${NC}"

if [ "$FLEXIBLE" = "true" ]; then
    echo -e "${GREEN}Flexible SSL is enabled. Skipping SSL certificate check.${NC}"
    NGINX_PORT=80
else
    echo -e "${GREEN}Checking for SSL certificates...${NC}"
    if [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
        echo -e "${GREEN}✅ SSL certificates found.${NC}"
        NGINX_PORT="443 ssl"
    else
        echo -e "${RED}❌ SSL certificates not found at $SSL_CERT_PATH and $SSL_KEY_PATH.${NC}"
        echo -e "${YELLOW}Please obtain valid SSL certificates for your domain before proceeding.${NC}"
        exit 1
    fi
fi

DATA_DIRECTORY=$(pwd)/.data
echo -e "${GREEN}Files: $DATA_DIRECTORY${NC}"

# --- Auto-detect Nginx configuration path ---
if [ -d /etc/nginx/sites-available ]; then
    NGINX_CONF_DIR="/etc/nginx/sites-available"
elif [ -d /etc/nginx/conf.d ]; then
    NGINX_CONF_DIR="/etc/nginx/conf.d"
else
    NGINX_CONF_DIR="/etc/nginx"
fi

echo -e "${GREEN}Detected Nginx configuration directory: ${NGINX_CONF_DIR}${NC}"

echo -e "${GREEN}Set NGINX_PORT as ${NGINX_PORT}.${NC}"

NGINX_CONF="${NGINX_CONF_DIR}/${DOMAIN}.conf"

echo -e "${GREEN}Creating ${NGINX_CONF}...${NC}"

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

	location / {
		default_type image/png;
		root ${DATA_DIRECTORY}/bancho/assets;
	}
}

server {
	listen 80;
	server_name a.${DOMAIN};

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

	location / {
		root ${DATA_DIRECTORY}/bancho/avatars;
		try_files \$uri \$uri.png \$uri.jpg \$uri.gif \$uri.jpeg \$uri.jfif /default.jpg = 404;
	}
}
EOF
fi

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

echo -e "${GREEN}Testing Nginx configuration...${NC}"
if sudo nginx -t; then
    sudo systemctl reload nginx
    echo -e "${GREEN}✅ Nginx reloaded successfully.${NC}"
else
    echo -e "${RED}❌ Nginx configuration test failed.${NC}"
    exit 1
fi

echo -e "${GREEN}Finished installing onl-docker to your machine.${NC}"
