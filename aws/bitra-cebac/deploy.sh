#!/usr/bin/env bash
#
# Deploya un stack de bitra cebac en AWS, con el perfil bitra-cebac.
#
#   ./deploy.sh <stack> review   # arma el change set y lo muestra; no aplica nada
#   ./deploy.sh <stack> apply    # aplica
#
# Stacks, en este orden:
#   base        ECR, security groups, ALB, cluster, logs, rol de ejecución, bucket
#               de subidas, y el certificado del ALB con su CNAME de validación
#   edge-cert   el certificado de CloudFront (us-east-1); se valida con ese CNAME
#   cognito     el user pool y el app client; si ya existe el stack de las
#               Lambdas (healthbook-cebac-cognito-auth), las engancha
#   ses         el dominio como identidad de SES (DKIM y DMARC en Route 53)
#   api         bitra-api: service, CloudFront y DNS   (IMAGE_TAG=cebac-<sha>)
#   web         bitra-web: service, CloudFront y DNS   (IMAGE_TAG=cebac-<sha>)
#   messaging   lis-messaging: service con Service Connect (IMAGE_TAG=cebac-<sha>);
#               va después del stack SAM lis-messaging-cebac (SES y colas)
#
# Las imágenes se suben antes a ECR (ver push-image.sh).
#
# Todos llevan los tags de config.sh. Ver lis-docs/infra/cebac-bitra-aws.md.

set -euo pipefail
# Git Bash convierte /bitra/... en rutas de Windows si no.
export MSYS_NO_PATHCONV=1

# En Git Bash, la ruta en formato Windows: aws.exe no entiende /c/... y con
# MSYS_NO_PATHCONV nadie la convierte.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
# shellcheck source=config.sh
source "$HERE/config.sh"

stack="${1:-}"
mode="${2:-review}"

aws_() { aws --profile "$PROFILE" "$@"; }

stack_output() { # stack región output
  aws_ --region "$2" cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" --output text 2>/dev/null || true
}

region="$REGION"
case "$stack" in
  edge-cert)
    region=us-east-1
    params=(Domain="$DOMAIN")
    ;;
  base)
    params=(Domain="$DOMAIN" HostedZoneId="$HOSTED_ZONE_ID" VpcId="$VPC_ID"
            SubnetIds="$SUBNET_IDS" CloudFrontPrefixList="$CLOUDFRONT_PREFIX_LIST"
            CebacIp="$CEBAC_IP")
    ;;
  ses)
    params=(Domain="$DOMAIN" HostedZoneId="$HOSTED_ZONE_ID")
    ;;
  cognito)
    lambdas=healthbook-cebac-cognito-auth
    params=(DefineAuthChallengeArn="$(stack_output $lambdas "$REGION" DefineAuthChallengeArn)"
            CreateAuthChallengeArn="$(stack_output $lambdas "$REGION" CreateAuthChallengeArn)"
            VerifyAuthChallengeArn="$(stack_output $lambdas "$REGION" VerifyAuthChallengeResponseArn)")
    ;;
  api|web)
    : "${IMAGE_TAG:?IMAGE_TAG=cebac-<sha> (el tag de la imagen en ECR)}"
    origin_verify=$(aws_ --region "$REGION" ssm get-parameter --with-decryption \
      --name /bitra/cebac/cloudfront/origin-verify --query Parameter.Value --output text)
    params=(ImageTag="$IMAGE_TAG" Domain="$DOMAIN" HostedZoneId="$HOSTED_ZONE_ID"
            EdgeCertificateArn="$(stack_output bitra-cebac-edge-cert us-east-1 CertificateArn)"
            OriginVerify="$origin_verify")
    if [ "$stack" = api ]; then
      params+=(DocumentsBucket="$DOCUMENTS_BUCKET" DbHost="$DB_HOST"
               DbDatabase="$DB_DATABASE" DbUsername="$DB_USERNAME")
    fi
    ;;
  messaging)
    : "${IMAGE_TAG:?IMAGE_TAG=cebac-<sha> (el tag de la imagen en ECR)}"
    sam=lis-messaging-cebac
    params=(ImageTag="$IMAGE_TAG" Domain="$DOMAIN" DbHost="$DB_HOST"
            ServicePolicyArn="$(stack_output $sam "$REGION" ServicePolicyArn)"
            ConfigurationSet="$(stack_output $sam "$REGION" EmailConfigurationSetName)"
            EmailEventsQueueUrl="$(stack_output $sam "$REGION" EmailEventsQueueUrl)"
            WhatsAppEventsQueueUrl="$(stack_output $sam "$REGION" WhatsAppEventsQueueUrl)")
    ;;
  *)
    sed -n '3,23p' "$0"
    exit 1
    ;;
esac

name="bitra-cebac-$stack"
args=(--region "$region" cloudformation deploy
      --stack-name "$name"
      --template-file "$HERE/$stack.yaml"
      --parameter-overrides "${params[@]}"
      --tags "${TAGS[@]}"
      --capabilities CAPABILITY_NAMED_IAM
      --no-fail-on-empty-changeset)

case "$mode" in
  review)
    aws_ "${args[@]}" --no-execute-changeset >/dev/null
    changeset=$(aws_ --region "$region" cloudformation list-change-sets --stack-name "$name" \
      --query 'reverse(sort_by(Summaries,&CreationTime))[0].ChangeSetId' --output text)
    aws_ --region "$region" cloudformation wait change-set-create-complete --change-set-name "$changeset" 2>/dev/null || true
    echo "Change set de $name ($region):"
    aws_ --region "$region" cloudformation describe-change-set --change-set-name "$changeset" \
      --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table
    echo "Para aplicar: $0 $stack apply"
    ;;
  apply)
    aws_ "${args[@]}"
    aws_ --region "$region" cloudformation describe-stacks --stack-name "$name" \
      --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
    ;;
  *)
    echo "Modo desconocido: $mode (review | apply)" >&2
    exit 1
    ;;
esac
