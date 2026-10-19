#!/usr/bin/env bash
# Removes every resource created by demo.sh (names read from .demo-env)
set -uo pipefail
cd "$(dirname "$0")"   # .demo-env is written next to demo.sh

[ -f .demo-env ] || { echo ".demo-env not found — nothing to clean up"; exit 1; }
# shellcheck disable=SC1091
source .demo-env

echo "Removing S3 trigger..."
aws s3api put-bucket-notification-configuration --bucket "$SRC_BUCKET" \
  --notification-configuration '{}' 2>/dev/null

echo "Deleting Lambda function and logs..."
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null
aws logs delete-log-group --log-group-name "/aws/lambda/${FUNCTION_NAME}" --region "$REGION" 2>/dev/null

echo "Emptying and deleting buckets..."
for B in "$SRC_BUCKET" "$DST_BUCKET"; do
  aws s3 rb "s3://$B" --force --region "$REGION" 2>/dev/null
done

echo "Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name thumb-demo-policy 2>/dev/null
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null

rm -rf package function.zip sample.jpg thumb-*.* .demo-env
echo "Cleanup complete."
