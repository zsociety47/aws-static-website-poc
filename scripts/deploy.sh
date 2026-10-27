#!/usr/bin/env bash
#
# Creates a private Simple Storage Service (S3) bucket and a CloudFront
# distribution that reads it through Origin Access Control (OAC). Uploads
# site/ and waits until the distribution is deployed.
#
# Safe to re-run. An existing bucket is reused only when its project tag
# matches this proof. Nothing is deleted.
#
# Usage: ./scripts/deploy.sh
# Reads AWS_PROFILE, AWS_REGION, BUCKET_NAME, and DOMAIN_NAME from .env.
# When DOMAIN_NAME is empty, this stops at the CloudFront hostname.
# It does not buy a domain and it does not create a hosted zone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

load_env
require_aws
require_settings

SITE_DIR="$REPO_ROOT/site"
OAC_NAME="oac-staticweb-poc"
HEADERS_NAME="rhp-staticweb-poc"
FUNCTION_NAME="fn-www-to-apex-staticweb"
# Published constant for alias records that point at CloudFront. Not an account id.
CLOUDFRONT_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$SITE_DIR/index.html" || ! -f "$SITE_DIR/404.html" ]]; then
  echo "site/ needs index.html and 404.html before this can upload anything." >&2
  exit 1
fi

say() {
  printf '%s\n' "$*"
}

# Runs a command. On failure, prints the output with account ids masked.
run_quiet() {
  if ! "$@" >"$TMP/out" 2>"$TMP/err"; then
    mask_account < "$TMP/err" >&2
    return 1
  fi
}

ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "Sign in first: aws login --profile ${AWS_PROFILE} --region ${AWS_REGION}" >&2
  exit 1
fi

say "Profile:  ${AWS_PROFILE}"
say "Region:   ${AWS_REGION}"
say "Bucket:   ${BUCKET_NAME}"
say "Account:  ************"
if [[ -n "$DOMAIN_NAME" ]]; then
  say "Domain:   ${DOMAIN_NAME}"
else
  say "Domain:   not set. This run stops at the CloudFront hostname."
fi
say
say "Cost: the bucket and the distribution have no monthly fee. A site this size"
say "is cents for storage and requests. The budget staticweb-poc-zeon01 emails"
say "above 1 USD of actual spend on S3, CloudFront, and Route 53."
say "This script does not buy a domain and does not create a hosted zone."
say

bucket_state() {
  local err code
  err="$(mktemp)"
  set +e
  aws_cli s3api head-bucket --bucket "$BUCKET_NAME" >"$err" 2>&1
  code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    echo exists
  elif grep -q '(404)' "$err"; then
    echo missing
  elif grep -q '(403)' "$err"; then
    echo taken
  else
    mask_account < "$err" >&2
    echo error
  fi
  rm -f "$err"
}

write_bucket_tags() {
  cat > "$TMP/bucket-tags.json" <<EOF
{
  "TagSet": [
    {"Key": "lifetime", "Value": "${LIFETIME_TAG}"},
    {"Key": "owner", "Value": "${OWNER_TAG}"},
    {"Key": "project", "Value": "${PROJECT_TAG}"},
    {"Key": "environment", "Value": "${ENVIRONMENT_TAG}"},
    {"Key": "created", "Value": "${CREATED}"}
  ]
}
EOF
}

write_cloudfront_tags() {
  cat > "$TMP/cf-tags.json" <<EOF
{
  "Items": [
    {"Key": "lifetime", "Value": "${LIFETIME_TAG}"},
    {"Key": "owner", "Value": "${OWNER_TAG}"},
    {"Key": "project", "Value": "${PROJECT_TAG}"},
    {"Key": "environment", "Value": "${ENVIRONMENT_TAG}"},
    {"Key": "created", "Value": "${CREATED}"}
  ]
}
EOF
}

say "==> Bucket"
state="$(bucket_state)"
case "$state" in
  exists)
    say "    Already exists. Checking its project tag."
    assert_our_bucket
    ;;
  missing)
    say "    Creating ${BUCKET_NAME}"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      run_quiet aws_cli s3api create-bucket --bucket "$BUCKET_NAME"
    else
      run_quiet aws_cli s3api create-bucket --bucket "$BUCKET_NAME" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
    fi
    ;;
  taken)
    echo "The bucket name ${BUCKET_NAME} belongs to another account. Pick a different BUCKET_NAME in .env." >&2
    exit 1
    ;;
  *)
    echo "Could not check the bucket. See the error above." >&2
    exit 1
    ;;
esac

CREATED="$(aws_cli s3api get-bucket-tagging --bucket "$BUCKET_NAME" \
  --query "TagSet[?Key=='created'].Value | [0]" --output text 2>/dev/null || true)"
if [[ -z "$CREATED" || "$CREATED" == "None" ]]; then
  CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

say "    Block Public Access, bucket-owner enforced, versioning, SSE-S3 encryption."
run_quiet aws_cli s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
run_quiet aws_cli s3api put-bucket-ownership-controls --bucket "$BUCKET_NAME" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
run_quiet aws_cli s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
run_quiet aws_cli s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
write_bucket_tags
run_quiet aws_cli s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "file://${TMP}/bucket-tags.json"
assert_our_bucket

say "==> Origin Access Control"
OAC_ID="$(aws_cli_global cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" --output text)"
if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
  say "    Creating ${OAC_NAME}"
  OAC_ID="$(aws_cli_global cloudfront create-origin-access-control \
    --origin-access-control-config "Name=${OAC_NAME},Description=Private S3 origin for ${PROJECT_TAG},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)"
else
  say "    Reusing ${OAC_NAME}"
fi

say "==> Security headers"
HEADERS_ID="$(aws_cli_global cloudfront list-response-headers-policies --type custom \
  --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='${HEADERS_NAME}'].ResponseHeadersPolicy.Id | [0]" \
  --output text)"
if [[ -z "$HEADERS_ID" || "$HEADERS_ID" == "None" ]]; then
  say "    Creating ${HEADERS_NAME}"
  cat > "$TMP/headers.json" <<EOF
{
  "Name": "${HEADERS_NAME}",
  "Comment": "Security headers for ${PROJECT_TAG}",
  "SecurityHeadersConfig": {
    "StrictTransportSecurity": {
      "Override": true,
      "IncludeSubdomains": true,
      "Preload": false,
      "AccessControlMaxAgeSec": 31536000
    },
    "ContentTypeOptions": {"Override": true},
    "FrameOptions": {"FrameOption": "DENY", "Override": true},
    "ReferrerPolicy": {"ReferrerPolicy": "strict-origin-when-cross-origin", "Override": true}
  }
}
EOF
  HEADERS_ID="$(aws_cli_global cloudfront create-response-headers-policy \
    --response-headers-policy-config "file://${TMP}/headers.json" \
    --query 'ResponseHeadersPolicy.Id' --output text)"
else
  say "    Reusing ${HEADERS_NAME}"
fi
# Origin Access Control and this headers policy cannot be tagged. AWS rejects
# those resource types. Teardown has to find them by name. The bucket and the
# distribution carry the tags.

CACHE_POLICY_ID="$(aws_cli_global cloudfront list-cache-policies --type managed \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingOptimized'].CachePolicy.Id | [0]" \
  --output text)"
if [[ -z "$CACHE_POLICY_ID" || "$CACHE_POLICY_ID" == "None" ]]; then
  echo "Could not find the managed cache policy Managed-CachingOptimized." >&2
  exit 1
fi

# Certificate and hostnames are added only after a domain exists.
# TLS 1.2 is a viewer setting on that certificate, not on the default hostname.
write_distribution_file() {
  local cert_arn="$1"
  local function_arn="$2"
  local alias_line="" viewer_json function_json
  if [[ -n "$cert_arn" ]]; then
    alias_line=$(printf '"Aliases": {"Quantity": 2, "Items": ["%s", "www.%s"]},' "$DOMAIN_NAME" "$DOMAIN_NAME")
    viewer_json=$(printf '{"CloudFrontDefaultCertificate": false, "ACMCertificateArn": "%s", "SSLSupportMethod": "sni-only", "MinimumProtocolVersion": "TLSv1.2_2021", "CertificateSource": "acm"}' "$cert_arn")
  else
    viewer_json='{"CloudFrontDefaultCertificate": true}'
  fi
  if [[ -n "$function_arn" ]]; then
    function_json=$(printf '{"Quantity": 1, "Items": [{"FunctionARN": "%s", "EventType": "viewer-request"}]}' "$function_arn")
  else
    function_json='{"Quantity": 0}'
  fi
  cat > "$TMP/distribution-update.json" <<EOF
{
    "CallerReference": "${PROJECT_TAG}",
    "Comment": "${PROJECT_TAG}",
    "Enabled": true,
    "DefaultRootObject": "index.html",
    "PriceClass": "PriceClass_100",
    "HttpVersion": "http2and3",
    "IsIPV6Enabled": true,
    ${alias_line}
    "Origins": {
      "Quantity": 1,
      "Items": [{
        "Id": "s3-staticweb",
        "DomainName": "${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": {"OriginAccessIdentity": ""}
      }]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "s3-staticweb",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "${CACHE_POLICY_ID}",
      "ResponseHeadersPolicyId": "${HEADERS_ID}",
      "Compress": true,
      "SmoothStreaming": false,
      "AllowedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"],
        "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
      },
      "TrustedSigners": {"Enabled": false, "Quantity": 0},
      "TrustedKeyGroups": {"Enabled": false, "Quantity": 0},
      "LambdaFunctionAssociations": {"Quantity": 0},
      "FunctionAssociations": ${function_json},
      "FieldLevelEncryptionId": ""
    },
    "CustomErrorResponses": {
      "Quantity": 2,
      "Items": [
        {"ErrorCode": 403, "ResponsePagePath": "/404.html", "ResponseCode": "404", "ErrorCachingMinTTL": 10},
        {"ErrorCode": 404, "ResponsePagePath": "/404.html", "ResponseCode": "404", "ErrorCachingMinTTL": 10}
      ]
    },
    "ViewerCertificate": ${viewer_json},
    "Restrictions": {"GeoRestriction": {"RestrictionType": "none", "Quantity": 0}}
}
EOF
  cat > "$TMP/distribution.json" <<EOF
{
  "DistributionConfig": $(cat "$TMP/distribution-update.json"),
  "Tags": {
    "Items": [
      {"Key": "lifetime", "Value": "${LIFETIME_TAG}"},
      {"Key": "owner", "Value": "${OWNER_TAG}"},
      {"Key": "project", "Value": "${PROJECT_TAG}"},
      {"Key": "environment", "Value": "${ENVIRONMENT_TAG}"},
      {"Key": "created", "Value": "${CREATED}"}
    ]
  }
}
EOF
}

say "==> CloudFront distribution"
found="$(aws_cli_global cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PROJECT_TAG}'].[Id,DomainName] | [0]" --output text)"
if [[ -z "$found" || "$found" == "None" ]]; then
  say "    Creating the distribution. The certificate on this hostname is the CloudFront default."
  say "    TLS 1.2 minimum is applied when your domain certificate is attached."
  write_distribution_file "" ""
  if ! found="$(aws_cli_global cloudfront create-distribution-with-tags \
      --distribution-config-with-tags "file://${TMP}/distribution.json" \
      --query 'Distribution.[Id,DomainName]' --output text 2>"$TMP/err")"; then
    mask_account < "$TMP/err" >&2
    exit 1
  fi
else
  say "    Reusing the distribution for ${PROJECT_TAG}"
fi
DIST_ID="${found%%$'\t'*}"
CF_DOMAIN="${found#*$'\t'}"
# text output can use spaces instead of a tab
if [[ "$CF_DOMAIN" == "$DIST_ID" ]]; then
  CF_DOMAIN="${found##* }"
  DIST_ID="${found%% *}"
fi

say "==> Bucket policy allows only this distribution to read objects"
cat > "$TMP/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalReadOnly",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
      }
    }
  }]
}
EOF
if ! aws_cli s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "file://${TMP}/policy.json" >"$TMP/out" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi
rm -f "$TMP/policy.json"

say "==> Uploading site/ (removed pages are deleted from the bucket)"
run_quiet aws_cli s3 sync "$SITE_DIR" "s3://${BUCKET_NAME}" --delete --exclude ".DS_Store" --exclude "*.DS_Store"
say "    Upload finished. Old versions stay in the bucket until teardown."

say "==> Waiting until CloudFront reports Deployed. This often takes 5 to 15 minutes."
if ! aws_cli_global cloudfront wait distribution-deployed --id "$DIST_ID" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi

say "==> Clearing the edge cache for /* (one invalidation path)"
INV_ID="$(aws_cli_global cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/*' \
  --query 'Invalidation.Id' --output text)"
say "    Invalidation ${INV_ID}"

say
say "CloudFront hostname: ${CF_DOMAIN}"
say "Site URL:            https://${CF_DOMAIN}/"
if [[ -z "$DOMAIN_NAME" ]]; then
  say
  say "DOMAIN_NAME is empty, so the domain steps were skipped."
  say "After you buy a domain in the Route 53 console, set DOMAIN_NAME in .env and run this script again."
  say "The apex name will be the site. www will redirect to it. This script will not register the domain."
  exit 0
fi

say "==> Domain ${DOMAIN_NAME}"
say "    Looking for an existing hosted zone. This script will not create one."
ZONE_ID="$(aws_cli_global route53 list-hosted-zones-by-name --dns-name "${DOMAIN_NAME}" --max-items 1 \
  --query "HostedZones[?Name=='${DOMAIN_NAME}.'].Id | [0]" --output text)"
ZONE_ID="${ZONE_ID#/hostedzone/}"
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
  echo "No hosted zone for ${DOMAIN_NAME}. Buy the domain in the Route 53 console, then run this script again." >&2
  exit 1
fi

say "    Requesting a certificate in ${CERT_REGION}"
CERT_ARN="$(aws_cli_global acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN_NAME}'].CertificateArn | [0]" --output text)"
if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
  if ! CERT_ARN="$(aws_cli_global acm request-certificate \
      --domain-name "$DOMAIN_NAME" \
      --subject-alternative-names "www.${DOMAIN_NAME}" \
      --validation-method DNS \
      --idempotency-token staticwebzeon01 \
      --query CertificateArn --output text 2>"$TMP/err")"; then
    mask_account < "$TMP/err" >&2
    exit 1
  fi
fi

say "    Writing the DNS validation records"
ready=""
for _try in 1 2 3 4 5 6; do
  aws_cli_global acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord.[Name,Type,Value]' --output text > "$TMP/validation.txt" 2>"$TMP/err" || true
  if grep -q 'CNAME' "$TMP/validation.txt"; then
    ready=yes
    break
  fi
  say "    Validation records are not ready yet. Waiting 10 seconds."
  sleep 10
done
if [[ -z "$ready" ]]; then
  echo "The certificate did not return DNS validation records. Run this script again in a minute." >&2
  exit 1
fi

{
  printf '%s\n' "{\"Comment\":\"Certificate validation for ${DOMAIN_NAME}\",\"Changes\":["
  first=yes
  while read -r name rtype value; do
    [[ -z "${name:-}" ]] && continue
    if [[ "$first" == yes ]]; then
      first=no
    else
      printf ',\n'
    fi
    printf '{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"%s","TTL":300,"ResourceRecords":[{"Value":"%s"}]}}' \
      "$name" "$rtype" "$value"
  done < "$TMP/validation.txt"
  printf '\n]}\n'
} > "$TMP/changes.json"
if ! grep -q 'UPSERT' "$TMP/changes.json"; then
  echo "The certificate did not return DNS validation records. Run this script again in a minute." >&2
  exit 1
fi
if ! aws_cli_global route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://${TMP}/changes.json" >"$TMP/out" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi

say "    Waiting for the certificate to be issued"
if ! aws_cli_global acm wait certificate-validated --certificate-arn "$CERT_ARN" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi

say "    Publishing the www redirect"
FUNC_ETAG="$(aws_cli_global cloudfront describe-function --name "$FUNCTION_NAME" --stage DEVELOPMENT \
  --query ETag --output text 2>/dev/null || true)"
if [[ -z "$FUNC_ETAG" || "$FUNC_ETAG" == "None" ]]; then
  aws_cli_global cloudfront create-function --name "$FUNCTION_NAME" \
    --function-config "Comment=Redirect www to the apex,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://${SCRIPT_DIR}/www-redirect.js" >"$TMP/out"
  FUNC_ETAG="$(aws_cli_global cloudfront describe-function --name "$FUNCTION_NAME" --stage DEVELOPMENT --query ETag --output text)"
else
  aws_cli_global cloudfront update-function --name "$FUNCTION_NAME" --if-match "$FUNC_ETAG" \
    --function-config "Comment=Redirect www to the apex,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://${SCRIPT_DIR}/www-redirect.js" >"$TMP/out"
  FUNC_ETAG="$(aws_cli_global cloudfront describe-function --name "$FUNCTION_NAME" --stage DEVELOPMENT --query ETag --output text)"
fi
aws_cli_global cloudfront publish-function --name "$FUNCTION_NAME" --if-match "$FUNC_ETAG" >"$TMP/out"
FUNC_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:function/${FUNCTION_NAME}"

say "    Attaching the certificate and the two hostnames"
DIST_ETAG="$(aws_cli_global cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)"
write_distribution_file "$CERT_ARN" "$FUNC_ARN"
if ! aws_cli_global cloudfront update-distribution --id "$DIST_ID" --if-match "$DIST_ETAG" \
    --distribution-config "file://${TMP}/distribution-update.json" >"$TMP/out" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi

say "    Alias records for the apex and for www"
cat > "$TMP/alias.json" <<EOF
{
  "Comment": "Point ${DOMAIN_NAME} at CloudFront",
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "${DOMAIN_NAME}", "Type": "A", "AliasTarget": {"HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}", "DNSName": "${CF_DOMAIN}", "EvaluateTargetHealth": false}}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "${DOMAIN_NAME}", "Type": "AAAA", "AliasTarget": {"HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}", "DNSName": "${CF_DOMAIN}", "EvaluateTargetHealth": false}}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "www.${DOMAIN_NAME}", "Type": "A", "AliasTarget": {"HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}", "DNSName": "${CF_DOMAIN}", "EvaluateTargetHealth": false}}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "www.${DOMAIN_NAME}", "Type": "AAAA", "AliasTarget": {"HostedZoneId": "${CLOUDFRONT_HOSTED_ZONE_ID}", "DNSName": "${CF_DOMAIN}", "EvaluateTargetHealth": false}}}
  ]
}
EOF
if ! aws_cli_global route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://${TMP}/alias.json" >"$TMP/out" 2>"$TMP/err"; then
  mask_account < "$TMP/err" >&2
  exit 1
fi

say "    Waiting for the distribution to deploy the certificate"
aws_cli_global cloudfront wait distribution-deployed --id "$DIST_ID"
say
say "Site URL: https://${DOMAIN_NAME}/"
say "www redirects to the apex."
