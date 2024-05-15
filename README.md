# actions-opentofu

Для использования данного набора actions необходимо:
- выполнить checkout коммита с файлами манифеста

        uses: actions/checkout@v4
- далее поседовательно выполнить setup, init, validate, plan

        uses: ${{ gitea.server_url }}/lab/opentofu/setup@v1
        uses: ${{ gitea.server_url }}/lab/opentofu/init@v1
            with:
            manifest_path: manifest # директория с файлами вашего манифеста, если в файлы в корне проекта - параметр manifest_path не задавать
            backend_type: s3 # (s3 или consul) тип бэкенда, должен быть такой же, как  объявлен в секции 'terraform{ backend: "backend_type" }' 
 - далее в зависимости от backend_type необходимо передать один из наборов параметров
    - Для s3

            uses: ${{ gitea.server_url }}/lab/opentofu/init@v1
            with:
                manifest_path: manifest
                backend_type: s3
                s3_address: # FQDN сервера s3
                s3_bucket: bucket_name # Имя бакета в s3
                s3_path: path/state # Путь (path) по которому в бакете будет сохранен файл (state), расширение .tfstate добавляется автоматически
                s3_key: ${{ secrets.s3_access_token }} # Токен доступа с правами на запись
                s3_secret: ${{ secrets.s3_secret_token }} # Секретный токен доступа
    - Для consul

            uses: ${{ gitea.server_url }}/lab/opentofu/init@v1
            with:
                manifest_path: manifest
                backend_type: consul
                consul_address: # FQDN сервера consul, default: 'consul.office.softline.ru'
                consul_scheme: # http/https, default: 'https'
                consul_path: ${{ gitea.repository }}/prod # путь по которому будет доступен state в kv consul
                consul_token: ${{ secrets.consul_token }} # токен от consul с правом записи в kv по пути opentofu/consul_path
- Затем validate и plan

        uses: ${{ gitea.server_url }}/lab/opentofu/validate@v1
        with:
            manifest_path: manifest
        uses: ${{ gitea.server_url }}/lab/opentofu/plan@v1
        with:
            manifest_path: manifest

- После выполнения tofu plan можно добавить

        uses: ${{ gitea.server_url }}/lab/opentofu/apply@v1
        with:
          manifest_path: manifest
- Для удаления виртуальных машин вместо apply необходимо вызвать destroy

        uses: ${{ gitea.server_url }}/lab/opentofu/destroy@v1
        with:
          manifest_path: manifest

Недостающие перменные необходимо задавать в секции env с префиксом 'TF_VAR_'

        env:
          TF_VAR_LOCAL_PASSWORD: "${{ secrets.local_password }}"
          TF_VAR_VSPHERE_PASSWORD: "${{ secrets.vsphere_password }}"
          TF_VAR_LOCAL_USER: "ansible"
          TF_VAR_VSPHERE_USER: "Softline\\svcSREvSphere"