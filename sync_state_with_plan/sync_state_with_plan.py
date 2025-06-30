import argparse
import json
import boto3
import requests
import os
import base64
import math
import hashlib
from botocore.exceptions import NoCredentialsError, PartialCredentialsError
from requests.auth import HTTPBasicAuth
from datetime import datetime

# Функция для скачивания стейта из S3
def download_state_from_s3(bucket_name, state_key):
    s3_scheme = os.getenv('TF_S3_SCHEME', 'http')
    s3 = boto3.client(
        's3',
        aws_access_key_id=os.getenv('TF_ACCESS_KEY'),
        aws_secret_access_key=os.getenv('TF_SECRET_KEY'),
        endpoint_url=f"{s3_scheme}://{os.getenv('TF_S3_ADDRESS')}"
    )
    try:
        s3.download_file(bucket_name, f"{state_key}.tfstate", 'terraform_state.json')
        print("State file downloaded from S3")
    except (NoCredentialsError, PartialCredentialsError):
        print("Credentials not available for S3.")
        exit(1)

# Функция для скачивания чанка стейта из consul
def download_chunk(consul_url, headers):
    response = requests.get(consul_url, headers=headers)
    response.raise_for_status()
    data = response.json()
    encoded = data[0]['Value']
    return base64.b64decode(encoded).decode('utf-8')

# Функция для скачивания стейта из Consul
def download_state_from_consul():
    consul_address = os.getenv('TF_CONSUL_ADDRESS')
    consul_scheme = os.getenv('TF_CONSUL_SCHEME', 'http')
    access_token = os.getenv('TF_ACCESS_TOKEN')
    state_key = os.getenv('TF_PATH')
    base_url = f"{consul_scheme}://{consul_address}/v1/kv/opentofu/{state_key}.tfstate"
    headers = {'X-Consul-Token': access_token} if access_token else {}

    response = requests.get(base_url, headers=headers)
    if response.status_code != 200:
        print("Failed to download state file from Consul.")
        exit(1)

    data = response.json()[0]
    decoded_data = base64.b64decode(data['Value']).decode('utf-8')

    try:
        obj = json.loads(decoded_data)
    except json.JSONDecodeError:
        # Если не JSON, записываем как есть
        with open('terraform_state.json', 'w') as f:
            f.write(decoded_data)
        print("State file downloaded from Consul")
        return

    if 'chunks' in obj:
        chunks = obj['chunks']
        full_state = ''
        for chunk_key in chunks:
            chunk_url = f"{consul_scheme}://{consul_address}/v1/kv/{chunk_key}"
            chunk_data = download_chunk(chunk_url, headers)
            full_state += chunk_data
        with open('terraform_state.json', 'w') as f:
            f.write(full_state)
    else:
        with open('terraform_state.json', 'w') as f:
            f.write(decoded_data)

    print("State file downloaded from Consul")

# Функция для загрузки стейта в S3
def upload_state_to_s3(bucket_name, state_key):
    s3_scheme = os.getenv('TF_S3_SCHEME', 'http')
    s3 = boto3.client(
        's3',
        aws_access_key_id=os.getenv('TF_ACCESS_KEY'),
        aws_secret_access_key=os.getenv('TF_SECRET_KEY'),
        endpoint_url=f"{s3_scheme}://{os.getenv('TF_S3_ADDRESS')}"
    )
    try:
        backup_state_key = f"{state_key}.tfstate.backup_{datetime.now().strftime('%Y_%m_%d_%H-%M')}"
        s3.copy_object(Bucket=bucket_name, CopySource={'Bucket': bucket_name, 'Key': f"{state_key}.tfstate"}, Key=backup_state_key)
        print(f"Backup state file created in S3: {backup_state_key}")

        s3.upload_file('new_terraform_state.json', bucket_name, f"{state_key}.tfstate")
        print("State file uploaded to S3")
    except (NoCredentialsError, PartialCredentialsError):
        print("Credentials not available for S3.")
        exit(1)

# Функция для загрузки чанка стейта в consul
def upload_chunk(consul_url, headers, data):
    response = requests.put(consul_url, headers=headers, data=data)
    if response.status_code != 200:
        print(f"Failed to upload chunk {consul_url}")
        exit(1)

# Функция для загрузки стейта в Consul
def upload_state_to_consul():
    consul_address = os.getenv('TF_CONSUL_ADDRESS')
    consul_scheme = os.getenv('TF_CONSUL_SCHEME', 'http')
    access_token = os.getenv('TF_ACCESS_TOKEN')
    state_key = os.getenv('TF_PATH')
    base_key = f"opentofu/{state_key}.tfstate"
    headers = {'X-Consul-Token': access_token} if access_token else {}

    with open('terraform_state.json', 'r') as f:
        state_content = f.read()

    # Создаём резервную копию
    backup_key = f"opentofu/{state_key}.backup_{datetime.now().strftime('%Y_%m_%d_%H-%M')}"
    backup_url = f"{consul_scheme}://{consul_address}/v1/kv/{backup_key}"
    backup_resp = requests.put(backup_url, headers=headers, data=state_content)
    if backup_resp.status_code != 200:
        print("Failed to create backup state file in Consul.")
        exit(1)
    print(f"Backup state file created in Consul: {backup_key}")

    # Разбиваем на чанки
    chunk_size = 512 * 1024  # 512 Кб
    total_chunks = math.ceil(len(state_content) / chunk_size)
    hash_digest = hashlib.md5(state_content.encode()).hexdigest()

    chunk_keys = []
    for i in range(total_chunks):
        chunk_key = f"opentofu/{state_key}.tfstate/tfstate.{hash_digest}/{i}"
        chunk_url = f"{consul_scheme}://{consul_address}/v1/kv/{chunk_key}"
        chunk_data = state_content[i*chunk_size:(i+1)*chunk_size]
        upload_chunk(chunk_url, headers, chunk_data)
        chunk_keys.append(chunk_key)

    # Записываем основной ключ с метаданными
    main_obj = {
        "chunks": chunk_keys,
        "current-hash": hash_digest
    }
    main_url = f"{consul_scheme}://{consul_address}/v1/kv/{base_key}"
    main_resp = requests.put(main_url, headers=headers, data=json.dumps(main_obj))
    if main_resp.status_code != 200:
        print("Failed to upload main state metadata to Consul.")
        exit(1)

    print("State file uploaded to Consul with chunking")

# Функция для обновления стейта на основе плана
def update_state_from_plan(state_file, plan_file):
    with open(state_file, 'r') as state, open(plan_file, 'r') as plan:
        state_data = json.load(state)
        plan_data = json.load(plan)

        changes_log = []

        def update_attribute(attributes, keys, value, resource_name, resource_type, full_path):
            current = attributes
            for key in keys[:-1]:
                current = current.setdefault(key, {})
            last_key = keys[-1]
            if current.get(last_key) != value:
                changes_log.append({
                    "from": current.get(last_key),
                    "to": value,
                    "resource_name": resource_name,
                    "resource_type": resource_type,
                    "full_path": full_path
                })
                current[last_key] = value

        updated_state_data = json.loads(json.dumps(state_data))  # Создаем копию данных стейта

        for resource_change in plan_data.get("resource_changes", []):
            if resource_change["change"]["actions"] in (["update"], ["create", "delete"], ["delete", "create"]):
                resource_type = resource_change["type"]
                resource_name = resource_change["name"]
                changes = resource_change["change"]["after"]
                replace_paths = resource_change["change"].get("replace_paths", [])
                after_unknown = resource_change["change"].get("after_unknown", {})
                module = resource_change.get("module_address")
                index = resource_change.get("index", 0)

                # Находим соответствующий ресурс в состоянии
                matching_resources = [
                    resource for resource in state_data["resources"]
                    if resource["type"] == resource_type and resource["name"] == resource_name and resource.get("module") == module
                ]

                if len(matching_resources) > 1:
                    print(f"Warning: Multiple matching resources found for {resource_type} {resource_name}. Check state consistency.")

                for resource in matching_resources:
                    for instance in resource.get("instances", []):
                        if instance.get("index_key", 0) == index:
                            resource_index = state_data["resources"].index(resource)
                            instance_index = resource["instances"].index(instance)
                            for key, value in changes.items():
                                # Обрабатываем ключи, которые должны быть заменены полностью
                                if any(key.startswith(rp[0]) for rp in replace_paths):
                                    if value is not None:
                                        keys = key.split('.')
                                        full_path = f"resources.{resource_index}.instances.{instance_index}.attributes.{key}"
                                        update_attribute(updated_state_data["resources"][resource_index]["instances"][instance_index]["attributes"], keys, value, resource_name, resource_type, full_path)
                                    continue

                                # Пропускаем значения, которые неизвестны до применения, за исключением тех, что в replace_paths
                                if key in after_unknown and key not in [rp[0] for rp in replace_paths]:
                                    continue

                                # Применяем изменения только если значение изменилось
                                keys = key.split('.')
                                full_path = f"resources.{resource_index}.instances.{instance_index}.attributes.{key}"
                                update_attribute(updated_state_data["resources"][resource_index]["instances"][instance_index]["attributes"], keys, value, resource_name, resource_type, full_path)

        # Сохраняем обновлённый стейт с новым именем
        with open('new_terraform_state.json', 'w') as state:
            json.dump(updated_state_data, state, indent=2)

        # Сохраняем отладочную информацию об изменениях
        with open('changes_log.json', 'w') as log_file:
            json.dump(changes_log, log_file, indent=2)
            
        # Выводим содержимое файла changes_log.json
        print("Вот что изменилось в opentofu state:\n")
        print(json.dumps(changes_log, indent=2))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Update Terraform state based on plan")
    parser.add_argument("--plan", default="plan.json", help="Path to the Terraform plan file in JSON format")
    parser.add_argument("--state", default="terraform_state.json", help="Path to the Terraform state file in JSON format (for debug)")
    args = parser.parse_args()

    # Скачиваем стейт в зависимости от источника
    if os.getenv('TF_S3_ADDRESS') and os.getenv('TF_BUCKET') and os.getenv('TF_KEY'):
        bucket_name = os.getenv('TF_BUCKET')
        state_key = os.getenv('TF_KEY')
        download_state_from_s3(bucket_name, state_key)
        state_file = 'terraform_state.json'
    elif os.getenv('TF_CONSUL_ADDRESS') and os.getenv('TF_PATH'):
        download_state_from_consul()
        state_file = 'terraform_state.json'
    elif args.state:
        state_file = args.state
    else:
        print("No source provided for downloading the state file. Use environment variables for S3 or Consul.")
        exit(1)

    # Обновляем стейт на основе плана
    update_state_from_plan(state_file, args.plan)

    # Загружаем обновленный стейт обратно в источник
    if os.getenv('TF_S3_ADDRESS') and os.getenv('TF_BUCKET') and os.getenv('TF_KEY'):
        upload_state_to_s3(bucket_name, state_key)
    elif os.getenv('TF_CONSUL_ADDRESS') and os.getenv('TF_PATH'):
        upload_state_to_consul()