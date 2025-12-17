# pollz
mod backend
mod tap

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

# deploy tap to fly.io
deploy-tap:
    just tap::deploy

# deploy everything
deploy: deploy-tap deploy-backend deploy-frontend
