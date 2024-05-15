TF_CONSUL_ADDRESS=${TF_CONSUL_ADDRESS}
TF_CONSUL_SCHEME=${TF_CONSUL_SCHEME}
TF_ACCESS_TOKEN=${TF_ACCESS_TOKEN}
TF_PATH=${TF_PATH}
MANIFEST_DIR=${MANIFEST_DIR}

TOFU_OPTIONS="
  -chdir=$MANIFEST_DIR
"

COMMON_ARGS="
  -backend-config=address=${TF_CONSUL_ADDRESS} \
  -backend-config=scheme=${TF_CONSUL_SCHEME} \
  -backend-config=path=opentofu/${TF_PATH}.tfstate\
  -backend-config=access_token=${TF_ACCESS_TOKEN} \
  -backend-config=lock=true
"

if [ -z "$TF_STATE" ]; then
  echo ${COMMON_ARGS}
  tofu ${TOFU_OPTIONS} init ${COMMON_ARGS}
elif [ "$TF_STATE" = "reconfigure" ]; then
  tofu ${TOFU_OPTIONS} init -reconfigure ${COMMON_ARGS}
elif [ "$TF_STATE" = "migrate-state" ]; then
  tofu ${TOFU_OPTIONS} init -migrate-state ${COMMON_ARGS}
fi
