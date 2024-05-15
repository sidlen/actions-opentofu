TF_BUCKET=${TF_BUCKET}
TF_KEY=${TF_KEY}
TF_ACCESS_KEY=${TF_ACCESS_KEY}
TF_SECRET_KEY=${TF_SECRET_KEY}
TF_S3_ADDRESS=${TF_S3_ADDRESS}
MANIFEST_DIR=${MANIFEST_DIR}

TOFU_OPTIONS="
  -chdir=$MANIFEST_DIR
"

COMMON_ARGS="
  -backend-config=endpoint=$TF_S3_ADDRESS \
  -backend-config=bucket=$TF_BUCKET \
  -backend-config=key=$TF_KEY.tfstate \
  -backend-config=region=main \
  -backend-config=access_key=$TF_ACCESS_KEY \
  -backend-config=secret_key=$TF_SECRET_KEY \
  -backend-config=skip_credentials_validation=true \
  -backend-config=skip_metadata_api_check=true \
  -backend-config=skip_region_validation=true \
  -backend-config=force_path_style=true
"

if [ -z "$TF_STATE" ]; then
  echo ${COMMON_ARGS}
  tofu ${TOFU_OPTIONS} init ${COMMON_ARGS}
elif [ "$TF_STATE" = "reconfigure" ]; then
  tofu ${TOFU_OPTIONS} init -reconfigure ${COMMON_ARGS}
elif [ "$TF_STATE" = "migrate-state" ]; then
  tofu ${TOFU_OPTIONS} init -migrate-state ${COMMON_ARGS}
fi
