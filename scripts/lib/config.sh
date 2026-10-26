#!/usr/bin/env bash
#
# Shared checks for deploy.sh, verify.sh, and teardown.sh.
# Loads .env, requires an explicit profile and region, and masks account ids
# before anything is printed. Refuses to touch a bucket this proof did not tag.

# Repo root is two levels up from scripts/lib/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROJECT_TAG="01-aws-static-website-poc"
OWNER_TAG="zeon"
LIFETIME_TAG="1d"
ENVIRONMENT_TAG="poc"

# CloudFront accepts a certificate only from us-east-1.
# The bucket can move to another region. The certificate cannot.
CERT_REGION="us-east-1"

load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
  fi
}

require_aws() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "The AWS Command Line Interface (CLI) is not installed. Install version 2, then run this again." >&2
    exit 1
  fi
}

require_settings() {
  : "${AWS_PROFILE:=}"
  : "${AWS_REGION:=}"
  : "${BUCKET_NAME:=}"
  : "${DOMAIN_NAME:=}"

  if [[ -z "$AWS_PROFILE" || -z "$AWS_REGION" || -z "$BUCKET_NAME" ]]; then
    echo "Copy .env.example to .env and set AWS_PROFILE, AWS_REGION, and BUCKET_NAME." >&2
    exit 1
  fi

  if [[ ! "$AWS_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "AWS_PROFILE may contain only letters, digits, hyphens, and underscores." >&2
    exit 1
  fi

  if [[ ! "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    echo "AWS_REGION should look like us-east-1." >&2
    exit 1
  fi

  # Simple Storage Service (S3) bucket names are global. No underscores.
  if [[ ! "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    echo "BUCKET_NAME must be 3 to 63 characters: lowercase letters, digits, hyphens, and periods." >&2
    exit 1
  fi

  if [[ "$BUCKET_NAME" == *..* ]]; then
    echo "BUCKET_NAME cannot contain two periods in a row." >&2
    exit 1
  fi

  if [[ -n "$DOMAIN_NAME" && ! "$DOMAIN_NAME" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo "DOMAIN_NAME should look like example.com, with no www prefix. Leave it empty until the hosted zone exists." >&2
    exit 1
  fi
}

# Replaces a 12-digit account id. Distribution ids and bucket names are left as they are.
mask_account() {
  sed -E 's/[0-9]{12}/************/g'
}

# Every call names the profile and the region. There is no default-profile fallback.
aws_cli() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager "$@"
}

# CloudFront and AWS Certificate Manager (ACM) for this site are called in us-east-1.
aws_cli_global() {
  aws --profile "$AWS_PROFILE" --region "$CERT_REGION" --no-cli-pager "$@"
}

# Returns 0 only when the bucket carries this proof's project tag.
assert_our_bucket() {
  local project_tag
  project_tag="$(aws_cli s3api get-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --query "TagSet[?Key=='project'].Value | [0]" \
    --output text 2>/dev/null || true)"

  if [[ "$project_tag" != "$PROJECT_TAG" ]]; then
    echo "Refusing to touch s3://${BUCKET_NAME}." >&2
    echo "Its project tag is not ${PROJECT_TAG}." >&2
    exit 1
  fi
}
