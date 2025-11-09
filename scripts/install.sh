#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting onl stack installation...${NC}"

echo -e "${GREEN}Initializing git submodules...${NC}"

git submodule update --init --recursive

echo -e "${GREEN}Building Docker images...${NC}"

make build

echo -e "${GREEN}Finished installing onl-docker to your machine${NC}"