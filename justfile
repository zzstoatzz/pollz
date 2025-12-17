# pollz
mod backend

# show available commands
default:
    @just --list

# build frontend
build:
    pnpm build

# deploy frontend to cloudflare pages
deploy-frontend:
    pnpm build
    npx wrangler pages deploy dist --project-name=pollz-waow-tech --commit-dirty=true

# deploy backend to fly.io
deploy-backend:
    just backend::deploy

# deploy everything
deploy: deploy-backend deploy-frontend
