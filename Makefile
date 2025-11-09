COMPOSE ?= docker compose
.PHONY: help build run up down logs ps restart clean

install:
	scripts/install.sh

help:
	@printf "Usage:\n  make build   Build images\n  make run     Build (if needed) and start services in background\n  make up      Alias for run\n  make down    Stop and remove containers\n  make logs    Follow service logs\n  make ps      Show service status\n  make restart Restart services\n  make clean   Remove containers, images, volumes, orphans\n"

build:
	$(COMPOSE) build --parallel

run:
	$(COMPOSE) up

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

restart:
	$(COMPOSE) restart

clean:
	$(COMPOSE) down --rmi all --volumes --remove-orphans