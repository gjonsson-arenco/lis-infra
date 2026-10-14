# Lo fijo del deploy de bitra cebac en AWS. Lo lee deploy.sh.
# Relevado el 2026-10-13 (ver lis-docs/infra/cebac-bitra-aws.md).

PROFILE=bitra-cebac
REGION=sa-east-1
ACCOUNT_ID=340482984767

DOMAIN=cebac.bitra-care.com
# Zona de bitra-care.com en Route 53: los registros de cebac.* van directo ahí.
HOSTED_ZONE_ID=Z08346901MY23OWY258X6

# VPC default de la cuenta, la misma de healthbook-test (172.31.0.0/16).
VPC_ID=vpc-819c89e6
SUBNET_IDS=subnet-8e57d1e8,subnet-d64dc99f,subnet-94c844cf

# com.amazonaws.global.cloudfront.origin-facing en sa-east-1. Cuenta como 55
# reglas del security group del ALB (el límite es 60).
CLOUDFRONT_PREFIX_LIST=pl-5da64334

# IP pública de salida de CEBAC (sin /32). Vacía: el ALB no la deja entrar y
# msg.cebac.bitra-care.com no existe todavía.
CEBAC_IP=

# Base de bitra: healthbook-test, la copia de producción (no healthbook-cebac-pr).
DB_HOST=healthbook-test.ccf1edaxmims.sa-east-1.rds.amazonaws.com
DB_DATABASE=ebdb
DB_USERNAME=healthbook

# Los informes: el bucket de v1 en producción. bitra sólo lo lee; no se toca.
DOCUMENTS_BUCKET=healthbook-cebac-documents

# Tags de todos los stacks. CloudFormation los propaga a lo que crea.
TAGS=(Project=bitra Customer=cebac Environment=test ManagedBy=cloudformation)
