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

echo "Найдено child_modules: $module_count"

for ((i=0; i<module_count; i++)); do
  module_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].address")
  resource_count=$(echo "$plan_json" | jq ".planned_values.root_module.child_modules[$i].resources | length")
  echo "Найдено ресурсов в $module_name: $resource_count"
  
  # Обработка ресурсов внутри каждого child_module
  for ((j=0; j<resource_count; j++)); do
    resource_type=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].type")
    echo "Обрабатывается ресурс $j в $module_name типа $resource_type"
    
    if [ "$resource_type" == "vsphere_virtual_machine" ]; then
      # Логика для импорта vsphere_virtual_machine
      address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].address")
      folder=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.folder")
      name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.name")
      datacenter=$(echo "$plan_json" | jq -r --arg module_name "$module_name" '
        .prior_state.values.root_module.child_modules[]
        | select(.resources[].address | contains($module_name))
        | .resources[]
        | select(.type == "vsphere_datacenter" and .mode == "data")
        | .values.name' | head -n 1)
      
      echo "Ресурс $j в $module_name имеет адрес $address, папку $folder, имя $name, датацентр $datacenter"
      
      if [ -n "$folder" ] && [ -n "$name" ] && [ -n "$datacenter" ]; then
        import_command="tofu ${TOFU_OPTIONS} import $address \"/$datacenter/vm/$folder/$name\""
        import_commands+=("$import_command")
        echo "Команда для импорта: $import_command"
        $import_command
        if [ $? -eq 0 ]; then
          success_imports+=("$import_command")
        else
          failed_imports+=("$import_command")
        fi
      else
        echo "Пропуск ресурса $j в $module_name: папка, имя или датацентр отсутствуют"
      fi

    elif [ "$resource_type" == "vcd_vapp" ]; then
      # Логика для импорта vApp
      address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].address")
      org=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.org")
      vapp_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.name")
      vdc=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.vdc")
      
      echo "Ресурс $j в $module_name имеет адрес $address, организацию $org, vApp $vapp_name, VDC $vdc"
      
      if [ -n "$org" ] && [ -n "$vapp_name" ] && [ -n "$vdc" ]; then
        import_command="tofu ${TOFU_OPTIONS} import $address \"$org.$vdc.$vapp_name\""
        import_commands+=("$import_command")
        echo "Команда для импорта: $import_command"
        $import_command
        if [ $? -eq 0 ]; then
          success_imports+=("$import_command")
        else
          failed_imports+=("$import_command")
        fi
        
        # Импорт сети для vApp
        network_address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.org_network_name")
        if [ -n "$network_address" ]; then
          import_command="tofu ${TOFU_OPTIONS} import vcd_vapp_org_network.vappOrgNet \"$org.$vdc.$vapp_name.$network_address\""
          import_commands+=("$import_command")
          echo "Команда для импорта сети: $import_command"
          $import_command
          if [ $? -eq 0 ]; then
            success_imports+=("$import_command")
          else
            failed_imports+=("$import_command")
          fi
        fi

      else
        echo "Пропуск ресурса $j в $module_name: организация, vApp или VDC отсутствуют"
      fi

    elif [ "$resource_type" == "vcd_vapp_vm" ]; then
      # Логика для импорта vcd_vapp_vm
      address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].address")
      org=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.org")
      vapp_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.vapp_name")
      name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.name")
      
      echo "Ресурс $j в $module_name имеет адрес $address, организацию $org, vApp $vapp_name, имя ВМ $name"
      
      if [ -n "$org" ] && [ -n "$vapp_name" ] && [ -n "$name" ]; then
        import_command="tofu ${TOFU_OPTIONS} import $address \"$org.$vapp_name.$name\""
        import_commands+=("$import_command")
        echo "Команда для импорта: $import_command"
        $import_command
        if [ $? -eq 0 ]; then
          success_imports+=("$import_command")
        else
          failed_imports+=("$import_command")
        fi
      else
        echo "Пропуск ресурса $j в $module_name: организация, vApp или имя ВМ отсутствуют"
      fi

    elif [ "$resource_type" == "vcd_vm_internal_disk" ]; then
      # Логика для импорта дисков
      address=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].address")
      vapp_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.vapp_name")
      vm_name=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].values.vm_name")
      disk_label=$(echo "$plan_json" | jq -r ".planned_values.root_module.child_modules[$i].resources[$j].index")
      
      echo "Ресурс $j в $module_name имеет адрес $address, vApp $vapp_name, VM $vm_name, метка диска $disk_label"
      
      if [ -n "$vapp_name" ] && [ -n "$vm_name" ]; then
        import_command="tofu ${TOFU_OPTIONS} import $address \"$vapp_name.$vm_name.$disk_label\""
        import_commands+=("$import_command")
        echo "Команда для импорта: $import_command"
        $import_command
        if [ $? -eq 0 ]; then
          success_imports+=("$import_command")
        else
          failed_imports+=("$import_command")
        fi
      else
        echo "Пропуск ресурса $j в $module_name: vApp или VM отсутствуют"
      fi

    else
      echo "Пропуск ресурса $j в $module_name: тип не поддерживается"
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
