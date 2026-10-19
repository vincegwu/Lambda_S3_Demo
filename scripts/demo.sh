#!/usr/bin/env bash
# =============================================================================
# Demo: AWS Lambda + Amazon S3 — create a thumbnail when an image is uploaded
#
# Flow:  upload image -> S3 source bucket -> ObjectCreated event -> Lambda
#        (Pillow resize) -> thumbnail written to S3 destination bucket
#
# Run in AWS CloudShell, any Linux shell, or Git Bash on Windows
# (needs AWS CLI v2 + Python 3; uses `zip` if installed, else Python's zipfile).
# Files required in the same folder: lambda_function.py
#
# Usage (from any directory, e.g. the project root):
#         ./scripts/demo.sh                 # generates a sample image
#         ./scripts/demo.sh my-photo.jpg    # uses your own image
# Cleanup: ./scripts/cleanup.sh
# =============================================================================
set -euo pipefail

# Resolve the optional image path before switching directories
IMAGE_ARG=""
if [ -n "${1:-}" ]; then
  [ -f "$1" ] || { echo "Image not found: $1"; exit 1; }
  IMAGE_ARG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi
# Work from this script's folder: lambda_function.py, .demo-env and build files live here
cd "$(dirname "$0")"

# Windows (Git Bash): aws.exe prints CRLF, which would leak "\r" into captured names/ARNs
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) aws() { command aws "$@" | tr -d '\r'; } ;;
esac
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "Python 3 not found"; exit 1; }

# ---------- Config -----------------------------------------------------------
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
REGION="${REGION:-us-east-1}"
ARCH="${ARCH:-x86_64}"                 # x86_64 | arm64
RUNTIME="python3.14"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SUFFIX="$(date +%s | tail -c 6)"

SRC_BUCKET="thumb-demo-src-${ACCOUNT_ID}-${SUFFIX}"
DST_BUCKET="thumb-demo-dst-${ACCOUNT_ID}-${SUFFIX}"
FUNCTION_NAME="thumb-demo-fn-${SUFFIX}"
ROLE_NAME="thumb-demo-role-${SUFFIX}"
STATE_FILE=".demo-env"

PIP_ARCH=$([ "$ARCH" = "arm64" ] && echo aarch64 || echo x86_64)

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$*"; }

[ -f lambda_function.py ] || { echo "lambda_function.py not found in $(pwd)"; exit 1; }

# Persist names so cleanup.sh can remove everything
cat > "$STATE_FILE" <<EOF
REGION=$REGION
SRC_BUCKET=$SRC_BUCKET
DST_BUCKET=$DST_BUCKET
FUNCTION_NAME=$FUNCTION_NAME
ROLE_NAME=$ROLE_NAME
EOF

echo "Region: $REGION | Account: $ACCOUNT_ID | Arch: $ARCH | Runtime: $RUNTIME"

# ---------- 1. S3 buckets ----------------------------------------------------
step "1/7 Creating S3 buckets (separate source/destination prevents recursive invocation)"
for B in "$SRC_BUCKET" "$DST_BUCKET"; do
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$B" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$B" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  ok "s3://$B"
done

# ---------- 2. IAM execution role (least privilege) --------------------------
step "2/7 Creating IAM execution role"
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name thumb-demo-policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:*:*:*\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${SRC_BUCKET}/*\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::${DST_BUCKET}/*\"}
    ]
  }"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
ok "$ROLE_ARN"

# ---------- 3. Deployment package with Pillow --------------------------------
step "3/7 Building deployment package (Pillow manylinux wheel for $RUNTIME / $ARCH)"
rm -rf package function.zip
# --user is rejected inside a virtualenv; only use it for a system/global Python
PIP_USER="--user"
if "$PY" -c 'import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)'; then
  PIP_USER=""
fi
"$PY" -m pip install --quiet --upgrade $PIP_USER pip
"$PY" -m pip install --quiet pillow \
  --platform "manylinux_2_28_${PIP_ARCH}" --platform "manylinux2014_${PIP_ARCH}" \
  --implementation cp --python-version 3.14 \
  --only-binary=:all: --target package/
cp lambda_function.py package/
if command -v zip >/dev/null; then
  (cd package && zip -qr9 ../function.zip .)
else
  (cd package && "$PY" -m zipfile -c ../function.zip *)
fi
# Check the extracted file directly: `unzip -l | grep -q` trips SIGPIPE under pipefail
compgen -G "package/PIL/_imaging.cpython-314*.so" >/dev/null || { echo "Pillow binary missing"; ls package/PIL | head; exit 1; }
ok "function.zip ($(du -h function.zip | cut -f1))"

# ---------- 4. Lambda function -----------------------------------------------
step "4/7 Creating Lambda function (waiting for IAM role propagation)"
for i in $(seq 1 10); do
  if aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --architectures "$ARCH" \
      --handler lambda_function.lambda_handler \
      --role "$ROLE_ARN" \
      --zip-file fileb://function.zip \
      --memory-size 512 \
      --timeout 30 \
      --environment "Variables={DEST_BUCKET=${DST_BUCKET},THUMB_PREFIX=thumbnails/}" \
      --region "$REGION" >/dev/null 2>/tmp/create-fn.err; then
    break
  fi
  grep -q "cannot be assumed" /tmp/create-fn.err || { cat /tmp/create-fn.err; exit 1; }
  [ "$i" -eq 10 ] && { echo "IAM role did not propagate in time"; exit 1; }
  sleep 5
done
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$REGION"
FUNCTION_ARN="$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query Configuration.FunctionArn --output text)"
ok "$FUNCTION_ARN"

# ---------- 5. S3 -> Lambda trigger ------------------------------------------
step "5/7 Wiring S3 ObjectCreated event to Lambda"
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id s3-invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${SRC_BUCKET}" \
  --source-account "$ACCOUNT_ID" \
  --region "$REGION" >/dev/null

aws s3api put-bucket-notification-configuration --bucket "$SRC_BUCKET" \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\":[{
      \"Id\":\"thumbnail-trigger\",
      \"LambdaFunctionArn\":\"${FUNCTION_ARN}\",
      \"Events\":[\"s3:ObjectCreated:*\"]
    }]
  }"
ok "s3://$SRC_BUCKET  --(ObjectCreated)-->  $FUNCTION_NAME"

# ---------- 6. Upload an object ----------------------------------------------
step "6/7 Uploading image to source bucket"
if [ -n "$IMAGE_ARG" ]; then
  IMAGE="$IMAGE_ARG"
else
  IMAGE="sample.jpg"
  "$PY" -m pip install --quiet $PIP_USER pillow
  "$PY" - <<'PY'
from PIL import Image, ImageDraw
w, h = 1600, 1000
img = Image.new("RGB", (w, h))
d = ImageDraw.Draw(img)
for x in range(w):
    d.line([(x, 0), (x, h)], fill=(int(255 * x / w), 90, 255 - int(255 * x / w)))
d.rectangle([w//4, h//4, 3*w//4, 3*h//4], outline="white", width=12)
d.text((w//2 - 120, h//2 - 10), "Lambda + S3 demo", fill="white")
img.save("sample.jpg", quality=90)
PY
fi
KEY="uploads/$(basename "$IMAGE")"
aws s3 cp "$IMAGE" "s3://${SRC_BUCKET}/${KEY}" --region "$REGION" >/dev/null
ok "Uploaded $IMAGE -> s3://${SRC_BUCKET}/${KEY}"

# ---------- 7. Verify thumbnail ----------------------------------------------
step "7/7 Waiting for thumbnail in destination bucket"
THUMB_KEY="thumbnails/uploads/thumb-$(basename "$IMAGE")"
aws s3api wait object-exists --bucket "$DST_BUCKET" --key "$THUMB_KEY" --region "$REGION"
aws s3 cp "s3://${DST_BUCKET}/${THUMB_KEY}" "thumb-$(basename "$IMAGE")" --region "$REGION" >/dev/null
ok "Thumbnail: s3://${DST_BUCKET}/${THUMB_KEY}"

"$PY" - "$IMAGE" "thumb-$(basename "$IMAGE")" <<'PY'
import os, sys
from PIL import Image
for label, path in (("Original ", sys.argv[1]), ("Thumbnail", sys.argv[2])):
    with Image.open(path) as im:
        print(f"    {label}: {im.size[0]}x{im.size[1]}  {os.path.getsize(path)/1024:.1f} KB")
PY

echo
echo "Recent Lambda logs:"
sleep 5
aws logs tail "/aws/lambda/${FUNCTION_NAME}" --since 10m --region "$REGION" | tail -n 15 || true

printf '\n\033[1;32mDemo complete.\033[0m  Upload more:  aws s3 cp <img> s3://%s/uploads/\n' "$SRC_BUCKET"
echo "Tear down:  $(dirname "$0")/cleanup.sh"
