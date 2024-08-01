#!/bin/bash
MANIFEST_DIR=${TOFU_WORKSPACE}/${MANIFEST_DIR}
TOFU_OPTIONS="
  -chdir=$MANIFEST_DIR
"

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

echo "Найдено child_modules: $module_count"

for ((i=0; i<module_count; i++)); do
  module_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].address")
  resource_count=$(echo "$plan_json" | jq ".planned_values.root_module.child_modules[$i].resources | length")
  echo "Найдено ресурсов в $module_name: $resource_count"
  for ((j=0; j<resource_count; j++)); do
    resource_type=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].type")
    echo "Обрабатывается ресурс $j в $module_name типа $resource_type"
    if [ "$resource_type" == "vsphere_virtual_machine" ]; then
      address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].address")
      folder=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.folder")
      name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.name")
      echo "Ресурс $j в $module_name имеет адрес $address, папку $folder, имя $name"
      if [ -n "$folder" ] && [ -n "$name" ]; then
        import_command="tofu ${TOFU_OPTIONS} import $address $folder/$name"
        import_commands+=("$import_command")
        echo "Команда для импорта: $import_command"
        $import_command
        if [ $? -eq 0 ]; then
          success_imports+=("$import_command")
        else
          failed_imports+=("$import_command")
        fi
      else
        echo "Пропуск ресурса $j в $module_name: папка или имя отсутствуют"
      fi
    else
      echo "Пропуск ресурса $j в $module_name: не является vsphere_virtual_machine"
    fi
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
