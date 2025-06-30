import json
import os

TOFU_OPTIONS = f"-chdir={os.getenv('MANIFEST_PATH')}"
PLAN_FILE = os.getenv('PLAN_FILE', 'plan.json')
parallelism = f"-parallelism={os.getenv('PARALLELISM')}"

# Чтение JSON плана из файла
with open(PLAN_FILE, "r") as file:
    plan_json = json.load(file)

# Проверка содержимого плана
if not plan_json:
    print(f"Ошибка: Файл {PLAN_FILE} пустой или не существует.")
    exit(1)

# Генерация команд tofu import
import_commands = []
processed_resources = set()

# Основной цикл обработки ресурсов
child_modules = plan_json.get("planned_values", {}).get("root_module", {}).get("child_modules", [])
resources_root = plan_json.get("planned_values", {}).get("root_module", {}).get("resources", [])

print(f"Найдено child_modules: {len(child_modules)}")
print(f"Найдено ресурсов на верхнем уровне: {len(resources_root)}")

def import_resource(address, import_path, resource_type):
    if address not in processed_resources:
        import_command = f"tofu {TOFU_OPTIONS} import {parallelism} '{address}' '{import_path}'"
        import_commands.append(import_command)
        processed_resources.add(address)
        print(f"Команда для импорта ресурса типа {resource_type}: {import_command}")

# Функция для вычисления ID диска на основе bus_number и unit_number
def calculate_disk_id(bus_number, unit_number):
    base_id = 2000
    return base_id + (bus_number * 16) + unit_number

# Функция обработки vsphere_virtual_machine
def process_vsphere_vm(module, resource):
    address = resource["address"]
    values = resource["values"]
    folder = values.get("folder")
    name = values.get("name")
    datacenter = None

    for child_module in plan_json.get("prior_state", {}).get("values", {}).get("root_module", {}).get("child_modules", []):
        for res in child_module.get("resources", []):
            if res["type"] == "vsphere_datacenter" and res["mode"] == "data":
                datacenter = res["values"].get("name")
                break

    if folder and name and datacenter:
        import_resource(address, f"/{datacenter}/vm/{folder}/{name}", "vsphere_virtual_machine")
    else:
        print(f"Пропуск ресурса {address}: папка, имя или датацентр отсутствуют")

# Функция обработки vcd_vapp на верхнем уровне
def process_vcd_vapp_root(resource):
    address = resource["address"]
    values = resource["values"]
    org = values.get("org")
    vapp_name = values.get("name")
    vdc = values.get("vdc")

    if org and vapp_name and vdc:
        import_resource(address, f"{org}.{vdc}.{vapp_name}", "vcd_vapp")
    else:
        print(f"Пропуск ресурса {address}: организация, vApp или VDC отсутствуют")

# Функция обработки vcd_vapp_org_network на верхнем уровне
def process_vcd_vapp_org_network_root(resource):
    address = resource["address"]
    values = resource["values"]
    org = values.get("org") or plan_json.get("variables", {}).get("VCD_ORG", {}).get("value")
    network_name = values.get("org_network_name")
    vapp_name = values.get("vapp_name")
    vdc = values.get("vdc") or plan_json.get("variables", {}).get("vcd_org_vdc", {}).get("value")

    if org and network_name and vapp_name and vdc:
        import_resource(address, f"{org}.{vdc}.{vapp_name}.{network_name}", "vcd_vapp_org_network")
    else:
        print(f"Пропуск ресурса {address}: организация, сеть, VDC или vApp отсутствуют")

# Функция обработки vcd_vapp_vm
def process_vcd_vapp_vm(module, resource):
    address = resource["address"]
    values = resource["values"]
    org = values.get("org")
    vapp_name = values.get("vapp_name")
    name = values.get("name")
    vdc = values.get("vdc")

    if org and vapp_name and name and vdc:
        import_resource(address, f"{org}.{vdc}.{vapp_name}.{name}", "vcd_vapp_vm")

    # Обработка дисков, которые находятся в подмодулях ВМ
    for child_module in module.get("child_modules", []):
        for disk_resource in child_module.get("resources", []):
            if disk_resource["type"] == "vcd_vm_internal_disk":
                disk_address = disk_resource["address"]
                disk_values = disk_resource["values"]
                disk_name = disk_values.get("vm_name") or name
                disk_vapp_name = disk_values.get("vapp_name") or vapp_name
                disk_vdc = disk_values.get("vdc") or vdc
                bus_number = disk_values.get("bus_number", 0)
                unit_number = disk_values.get("unit_number", 0)
                disk_id = calculate_disk_id(bus_number, unit_number)

                if org and disk_vapp_name and disk_name and disk_vdc:
                    import_resource(f"{disk_address}", f"{org}.{disk_vdc}.{disk_vapp_name}.{disk_name}.{disk_id}", "vcd_vm_internal_disk")
                else:
                    print(f"Пропуск диска {disk_address}: не все необходимые параметры заданы")
    else:
        print(f"Пропуск ресурса {address}: организация, vApp, VDC или имя ВМ отсутствуют")

# Обработка ресурсов на верхнем уровне
for resource in resources_root:
    resource_type = resource["type"]
    print(f"Обрабатывается ресурс {resource['address']} на верхнем уровне типа {resource_type}")

    if resource_type == "vcd_vapp":
        process_vcd_vapp_root(resource)
    elif resource_type == "vcd_vapp_org_network":
        process_vcd_vapp_org_network_root(resource)
    else:
        print(f"Пропуск ресурса {resource['address']} на верхнем уровне: тип не поддерживается")

# Обработка модулей и ресурсов внутри них
for module in child_modules:
    module_name = module["address"]
    resources = module.get("resources", [])
    print(f"Найдено ресурсов в {module_name}: {len(resources)}")

    for resource in resources:
        resource_type = resource["type"]
        print(f"Обрабатывается ресурс {resource['address']} в {module_name} типа {resource_type}")

        if resource_type == "vsphere_virtual_machine":
            process_vsphere_vm(module, resource)
        elif resource_type == "vcd_vapp_vm":
            process_vcd_vapp_vm(module, resource)
        else:
            print(f"Пропуск ресурса {resource['address']} в {module_name}: тип не поддерживается")

# Запись команд в файл
with open("import_commands.sh", "w") as file:
    file.write("#!/bin/bash\n")
    for cmd in import_commands:
        file.write(cmd + "\n")

print("Все команды импорта записаны в файл import_commands.sh.")