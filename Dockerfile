# Seleciona a imagem a ser usada no container (recomendação: Python + Alpine)
FROM python:3.12-alpine

# Define o ambiente de trabalho dentro do container
WORKDIR /app

# Instalar dependências do sistema operacional (se necessário)
RUN apk add --no-cache \
    gcc \
    musl-dev \
    python3-dev

# Copiar a lista de dependências Python para o container
COPY requirements.txt .

# Instalar as bibliotecas necessárias para a aplicação Python
# (presentes no arquivo requirements.txt)
RUN pip install --no-cache-dir -r requirements.txt

# Copiar o restante do código-fonte para o container
COPY . .

# Criar o diretório para armazenamento dos logs
RUN mkdir -p /app/logs

# Define a porta utilizada pela aplicação
EXPOSE 5005

# Iniciar a aplicação
CMD ["python", "app.py"]
