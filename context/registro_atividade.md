# Registro da Atividade — Grafana Lab (Carnivorous Green House)

Aluno: Emanuel Gondim
Data: 17/11/2026

Ambiente: Linux, Docker Engine 29.8.0, Docker Compose 2.40.3

---

## 1. Configuração do Dockerfile

```dockerfile
FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache \
    gcc \
    musl-dev \
    python3-dev

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /app/logs

EXPOSE 5005

CMD ["python", "app.py"]
```

Decisões:

- `python:3.12-alpine`: segue a versão do README (Python 3.12) e a recomendação de Alpine do template.
- O `requirements.txt` é copiado e instalado **antes** do restante do código. Assim a camada das dependências fica em cache e não é refeita a cada alteração no código.
- `/app/logs` é criado porque o `app.py` grava em `./logs/app.log` (relativo ao `WORKDIR /app`).
- Foi criado um `.dockerignore` (`.git`, `.venv`, `logs/`, `*.db`, etc.) para não copiar arquivos desnecessários para a imagem.

## 2. Configuração do docker-compose

Itens preenchidos no template:

| Serviço | Imagem / build | Porta | Volumes |
|---|---|---|---|
| carnivorous-garden | build `Dockerfile`, `container_name: carnivorous-garden`, `restart: unless-stopped` | `5005:5005` | `./logs:/app/logs` |
| alloy | `grafana/alloy:latest`, `depends_on: carnivorous-garden, loki` | `12345:12345` | `./alloy-config.alloy:/etc/alloy/config.alloy`, `./logs:/tmp/app-logs` |
| loki | `grafana/loki:latest` | `3100:3100` | `./loki-config.yaml:/etc/loki/local-config.yaml` |
| grafana | `grafana/grafana:latest` | `3000:3000` | — (datasource criado no entrypoint) |

O ponto principal é o diretório `./logs` do host, montado nos dois containers:

- no app, em `/app/logs` (onde o Flask escreve `app.log`);
- no Alloy, em `/tmp/app-logs` (o caminho que o `alloy-config.alloy` monitora: `/tmp/app-logs/app.log`).

**Provisionamento do datasource Loki no Grafana (entrypoint + shell + heredoc):**

```yaml
    entrypoint:
      - sh
      - -euc
      - |
        mkdir -p /etc/grafana/provisioning/datasources
        cat <<EOF > /etc/grafana/provisioning/datasources/ds.yaml
        apiVersion: 1
        datasources:
          - name: Loki
            type: loki
            uid: loki
            access: proxy
            orgId: 1
            url: http://loki:3100
            basicAuth: false
            isDefault: true
            version: 1
            editable: false
        EOF
        /run.sh
```

Antes de iniciar o Grafana (`/run.sh`, o script padrão da imagem), o shell cria o arquivo de provisionamento com o heredoc. Com isso, o Loki já aparece como fonte de dados padrão, apontando para `http://loki:3100` (o nome do serviço na rede `loki`).

Validação da sintaxe:

```
$ docker compose config -q && echo OK
OK
```

## 3. Teste de execução dos serviços

```
$ docker compose up -d --build
$ docker compose ps
NAME                    IMAGE                            SERVICE              STATUS         PORTS
carnivorous-garden      grafana_lab-carnivorous-garden   carnivorous-garden   Up             0.0.0.0:5005->5005/tcp
grafana_lab-alloy-1     grafana/alloy:latest             alloy                Up             0.0.0.0:12345->12345/tcp
grafana_lab-grafana-1   grafana/grafana:latest           grafana              Up             0.0.0.0:3000->3000/tcp
grafana_lab-loki-1      grafana/loki:latest              loki                 Up             0.0.0.0:3100->3100/tcp
```

Verificação de cada serviço:

| Verificação | Comando | Resultado |
|---|---|---|
| App Python (porta 5005) | `curl -w "%{http_code}" localhost:5005` | `200` |
| Grafana (porta 3000) | `curl localhost:3000/api/health` | `200` |
| Alloy (porta 12345) | `curl localhost:12345/-/ready` | `200` |
| Loki (porta 3100) | `curl -G localhost:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({filename="/tmp/app-logs/app.log"}[1h]))'` | `"status":"success"` com a contagem de linhas (ver observação sobre `/ready` abaixo) |
| Datasource Loki no Grafana | `curl localhost:3000/api/datasources/uid/loki/health` | `{"message":"Data source successfully connected.","status":"OK"}` |
| Logs chegando no Loki via Grafana | `.../proxy/uid/loki/loki/api/v1/labels` | `["filename","level","service_name"]` |

Para gerar logs, a aplicação foi usada assim:

- cadastro de usuário, incluindo um cadastro duplicado (gera ERROR);
- logins com senha errada (gera WARNING);
- login correto e acesso ao dashboard;
- **modo de falhas** ativado (`/toggle_error_mode`) e vários ciclos de login/logout, gerando falhas aleatórias (ERROR, HTTP 500);
- logins de usuários inexistentes (WARNING).

Distribuição registrada em `logs/app.log`: 129 INFO, 6 WARNING, 6 ERROR.

## 4. Consultas no Grafana (Explore → fonte de dados Loki)

### Consulta 1 — todos os logs da aplicação

```logql
{filename="/tmp/app-logs/app.log"}
```

Retorna todo o fluxo coletado pelo Alloy. Exemplo de linhas:

```
time="2026-11-17 19:24:51,646" logger="__main__" level="INFO" message="path="/login" method="POST" status="401""
time="2026-11-17 19:24:51,646" logger="werkzeug" level="INFO" message="172.19.0.1 - - [17/Nov/2026 19:24:51] "POST /login HTTP/1.1" 401 -"
```

### Consulta 2 — somente erros (label `level` extraída pelo Alloy)

```logql
{level="ERROR"}
```

Resultado: 6 linhas, todas causadas pelo modo de falhas ou pelo cadastro duplicado:

```
level="ERROR" message="user="aluno" action="login" status="error" error="random failure due to error mode""
level="ERROR" message="user="unknown" action="logout" status="error" error="Failed to loggout.""
```

A label `level` só existe porque o bloco `loki.process` do Alloy faz o parse em logfmt (`stage.logfmt`) e promove o campo a label (`stage.labels`).

### Consulta 3 — avisos filtrados por texto

```logql
{level="WARNING"} |= "invalid credentials"
```

Une o seletor de label com um filtro de linha (`|=`) para encontrar as tentativas de login com credenciais inválidas:

```
level="WARNING" message="user="visitante3" action="login" status="failed" error="invalid credentials""
level="WARNING" message="user="visitante2" action="login" status="failed" error="invalid credentials""
level="WARNING" message="user="visitante1" action="login" status="failed" error="invalid credentials""
```

### Consulta 4 — métrica: quantidade de logs por nível na última hora

```logql
sum by (level) (count_over_time({filename="/tmp/app-logs/app.log"}[1h]))
```

Resultado (consulta instantânea):

| level | quantidade |
|---|---|
| INFO | 129 |
| WARNING | 6 |
| ERROR | 6 |
| (sem level) | 3 |

Os números batem com a contagem direta no arquivo `logs/app.log`. As 3 linhas sem `level` são a mensagem de inicialização do Werkzeug (`* Running on ...`), que não segue o formato logfmt da aplicação.

## 5. Observações

- Cada requisição aparece **3 vezes** como `path=... method=... status=...` no log. Isso acontece porque o `app.py` define três funções `log_response` com `@app.after_request`, e o Flask registra as três. Não afeta a coleta, mas infla a contagem de INFO.
- O endpoint `localhost:3100/ready` do Loki continua respondendo `Pattern Ingester not ready: waiting for 15s after being ready`, mesmo com o serviço em execução há vários minutos. Isso vem do `pattern_ingester` habilitado no `loki-config.yaml`, um componente opcional (detecção de padrões). Ingestão e consultas funcionam normalmente, como mostram as consultas da seção 4. Por isso a verificação do Loki foi feita com uma consulta à API, e não pelo `/ready`.
- As imagens usam a tag `latest`, como no README. Para tornar o ambiente reproduzível, o ideal seria fixar as versões.
- O Grafana com acesso anônimo de administrador e o `SECRET_KEY` fixo no código servem só para o laboratório local.
