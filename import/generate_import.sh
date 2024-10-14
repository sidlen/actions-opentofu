#!/bin/bash

MANIFEST_DIR=${TOFU_WORKSPACE}/${TOFU_MANIFEST_DIR}
TOFU_OPTIONS="-chdir=$MANIFEST_DIR"

# Чтение JSON плана из файла
plan_json=$(cat plan.json)

# Проверка содержимого плана
if [ -z "$plan_json" ]; then
  echo "Ошибка: Файл plan.json пустой или не существует."
  exit 1
fi

# Генерация команд tofu import
import_commands=()
success_imports=()
failed_imports=()

# Используем jq для парсинга JSON
module_count=$(echo "$plan_json" | jq '.planned_values.root_module.child_modules | length')
resource_count=$(echo "$plan_json" | jq ".planned_values.root_module.resources | length")

echo "Найдено child_modules: $module_count"
echo "Найдено ресурсов на верхнем уровне: $resource_count"

# Функция импорта ресурсов
import_resource() {
  local address="$1"
  local import_path="$2"
  local resource_type="$3"

  import_command="tofu ${TOFU_OPTIONS} import '$address' '$import_path'"
  import_commands+=("$import_command")
  echo "Команда для импорта ресурса типа $resource_type: $import_command"
  $import_command
  if [ $? -eq 0 ]; then
    success_imports+=("$import_command")
  else
    failed_imports+=("$import_command")
  fi
}

# Функция обработки vsphere_virtual_machine
process_vsphere_vm() {
  local module_name="$1"
  local resource_index="$2"

  address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].address")
  folder=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.folder")
  name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.name")
  datacenter=$(echo "$plan_json" | jq -r --arg module_name "$module_name" '
    .prior_state.values.root_module.child_modules[]
    | select(.resources[].address | contains($module_name))
    | .resources[]
    | select(.type == "vsphere_datacenter" and .mode == "data")
    | .values.name' | head -n 1)

  if [ -n "$folder" ] && [ -n "$name" ] && [ -n "$datacenter" ]; then
    import_resource "$address" "/$datacenter/vm/$folder/$name" "vsphere_virtual_machine"
  else
    echo "Пропуск ресурса $resource_index в $module_name: папка, имя или датацентр отсутствуют"
  fi
}

# Функция обработки vcd_vapp на верхнем уровне
process_vcd_vapp_root() {
  local resource_index="$1"

  address=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$resource_index].address")
  org=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$resource_index].values.org")
  vapp_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$resource_index].values.name")
  vdc=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$resource_index].values.vdc")

  if [ -n "$org" ] && [ -n "$vapp_name" ] && [ -n "$vdc" ]; then
    import_resource "$address" "'$org.$vdc.$vapp_name'" "vcd_vapp"

    # Импорт сети для vApp
    network_address=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$resource_index].values.org_network_name")
    if [ -n "$network_address" ]; then
      import_resource "vcd_vapp_org_network.vappOrgNet" "'$org.$vdc.$vapp_name.$network_address'" "vcd_vapp_network"
    fi
  else
    echo "Пропуск ресурса $resource_index: организация, vApp или VDC отсутствуют"
  fi
}

# Функция обработки vcd_vapp_vm
process_vcd_vapp_vm() {
  local module_name="$1"
  local resource_index="$2"

  address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].address")
  org=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.org")
  vapp_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.vapp_name")
  name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.name")
  vdc=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.vdc")

  if [ -n "$org" ] && [ -n "$vapp_name" ] && [ -n "$name" ]; then
    import_resource "$address" "'$org.$vdc.$vapp_name.$name'" "vcd_vapp_vm"

    # Цикл для обработки внутренних дисков каждой VM
    local disk_count=$(echo "$plan_json" | jq ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.internal_disk | length")
    for ((k=0; k<disk_count; k++)); do
      disk_label=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$module_name].resources[$resource_index].values.internal_disk[$k].disk_id")
      import_resource "$address.disk[$k]" "'$org.$vdc.$vapp_name.$name.$disk_label'" "vcd_vm_internal_disk"
    done
  else
    echo "Пропуск ресурса $resource_index в $module_name: организация, vApp или имя ВМ отсутствуют"
  fi
}

# Основной цикл обработки модулей и ресурсов
for ((i=0; i<resource_count; i++)); do
  resource_type=$(echo "$plan_json" | jq -r ".planned_values.root_module.resources[$i].type")
  echo "Обрабатывается ресурс $i на верхнем уровне типа $resource_type"

  case $resource_type in
    "vcd_vapp")
      process_vcd_vapp_root "$i"
      ;;
    *)
      echo "Пропуск ресурса $i на верхнем уровне: тип не поддерживается"
      ;;
  esac
done

for ((i=0; i<module_count; i++)); do
  module_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].address")
  resource_count=$(echo "$plan_json" | jq ".planned_values.root_module.child_modules[$i].resources | length")
  echo "Найдено ресурсов в $module_name: $resource_count"

  for ((j=0; j<resource_count; j++)); do
    resource_type=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].type")
    echo "Обрабатывается ресурс $j в $module_name типа $resource_type"

    case $resource_type in
      "vsphere_virtual_machine")
        process_vsphere_vm "$i" "$j"
        ;;
      "vcd_vapp_vm")
        process_vcd_vapp_vm "$i" "$j"
        ;;
      *)
        echo "Пропуск ресурса $j в $module_name: тип не поддерживается"
        ;;
    esac
  done
done

# Вывод результатов
echo -e "\nРезультаты импорта:"
if [ ${#success_imports[@]} -ne 0 ]; then
  echo -e "\e[32mУспешно импортированные ресурсы:\e[0m"
  for cmd in "${success_imports[@]}"; do
    echo -e "\e[32m$cmd\e[0m"
  done
fi

if [ ${#failed_imports[@]} -ne 0 ]; then
  echo -e "\e[31mНеуспешно импортированные ресурсы:\e[0m"
  for cmd in "${failed_imports[@]}"; do
    echo -e "\e[31m$cmd\e[0m"
  done
  exit 1
fi

echo "Все команды импорта выполнены успешно."
