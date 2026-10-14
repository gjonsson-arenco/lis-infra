#!/usr/bin/env bash
#
# Construye una imagen de bitra cebac y la sube a ECR. Imprime el tag para
# deploy.sh:
#
#   tag=$(./push-image.sh api) && IMAGE_TAG=$tag ./deploy.sh api apply
#   tag=$(./push-image.sh web) && IMAGE_TAG=$tag ./deploy.sh web apply
#   tag=$(./push-image.sh messaging) && IMAGE_TAG=$tag ./deploy.sh messaging apply
#
# El tag es cebac-<sha corto del repo>; si el repo tiene cambios sin commitear,
# lleva -dirty-<hora> para que nunca pise una imagen hecha desde un commit.
# Los repos se buscan al lado de lis-infra (C:\Projects\LIS\...).

set -euo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
# shellcheck source=config.sh
source "$HERE/config.sh"
ROOT="$(cd "$HERE/../../.." && { pwd -W 2>/dev/null || pwd; })"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

image="${1:-}"
case "$image" in
  api)
    repository=bitra-api
    repo_dir="$ROOT/lis-healthbook/lis-healthbook-back"
    build=(docker build -t "$repository:build" "$repo_dir")
    ;;
  messaging)
    repository=lis-messaging
    repo_dir="$ROOT/lis-messaging-service"
    build=(docker build -t "$repository:build" "$repo_dir")
    ;;
  web)
    repository=bitra-web
    repo_dir="$ROOT/lis-healthbook/lis-healthbook-front"
    client_id=$(aws_ cloudformation describe-stacks --stack-name bitra-cebac-cognito \
      --query "Stacks[0].Outputs[?OutputKey=='AppClientId'].OutputValue" --output text)
    build=(docker build -f "$repo_dir/apps/web/Dockerfile" -t "$repository:build"
           --build-arg "NEXT_PUBLIC_API_URL=https://api.$DOMAIN/api/v1"
           --build-arg NEXT_PUBLIC_AUTH_MODE=cognito
           --build-arg "NEXT_PUBLIC_COGNITO_REGION=$REGION"
           --build-arg "NEXT_PUBLIC_COGNITO_CLIENT_ID=$client_id"
           --build-arg NEXT_PUBLIC_BITRA_CLIENT=cebac
           "$repo_dir")
    ;;
  *)
    sed -n '3,14p' "$0"
    exit 1
    ;;
esac

tag="cebac-$(git -C "$repo_dir" rev-parse --short HEAD)"
if [ -n "$(git -C "$repo_dir" status --porcelain)" ]; then
  tag="$tag-dirty-$(date +%Y%m%d%H%M)"
fi

registry="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
uri="$registry/$repository:$tag"

{
  "${build[@]}"
  aws_ ecr get-login-password | docker login --username AWS --password-stdin "$registry"
  docker tag "$repository:build" "$uri"
  docker push "$uri"
} >&2

echo "$tag"
