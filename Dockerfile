# Use an official Python runtime as a parent image
FROM python:3.11-slim-bullseye

# Set the working directory in the container
WORKDIR /MoneyPrinterTurbo

# 设置/MoneyPrinterTurbo目录权限为777
RUN chmod 777 /MoneyPrinterTurbo

ENV PYTHONPATH="/MoneyPrinterTurbo"

# Install system dependencies with domestic mirrors first for stability
RUN echo "deb http://mirrors.aliyun.com/debian bullseye main" > /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/debian-security bullseye-security main" >> /etc/apt/sources.list && \
    ( \
        for i in 1 2 3; do \
            echo "Attempt $i: Using Aliyun mirror"; \
            apt-get update && apt-get install -y --no-install-recommends \
                git \
                imagemagick \
                ffmpeg && break || \
            echo "Attempt $i failed, retrying..."; \
            if [ $i -eq 3 ]; then \
                echo "Aliyun mirror failed, switching to Tsinghua mirror"; \
                sed -i 's/mirrors.aliyun.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list && \
                sed -i 's/mirrors.aliyun.com\/debian-security/mirrors.tuna.tsinghua.edu.cn\/debian-security/g' /etc/apt/sources.list && \
                ( \
                    apt-get update && apt-get install -y --no-install-recommends \
                        git \
                        imagemagick \
                        ffmpeg || \
                    ( \
                        echo "Tsinghua mirror failed, switching to default Debian mirror"; \
                        sed -i 's/mirrors.tuna.tsinghua.edu.cn/deb.debian.org/g' /etc/apt/sources.list && \
                        sed -i 's/mirrors.tuna.tsinghua.edu.cn\/debian-security/security.debian.org/g' /etc/apt/sources.list; \
                        apt-get update && apt-get install -y --no-install-recommends \
                            git \
                            imagemagick \
                            ffmpeg; \
                    ); \
                ); \
            fi; \
            sleep 5; \
        done \
    ) && rm -rf /var/lib/apt/lists/*

# Fix security policy for ImageMagick
RUN sed -i '/<policy domain="path" rights="none" pattern="@\*"/d' /etc/ImageMagick-6/policy.xml

# Copy only the requirements.txt first to leverage Docker cache
COPY requirements.txt ./

# Install Python dependencies with domestic mirrors first and retry logic
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com --retries 3 --timeout 60 -r requirements.txt || \
    pip install --no-cache-dir -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/ --trusted-host mirrors.tuna.tsinghua.edu.cn --retries 3 --timeout 60 -r requirements.txt || \
    pip install --no-cache-dir --retries 3 --timeout 60 -r requirements.txt

# Install Codex CLI and Claude Code CLI for llm_provider = "codexcli" / "claudecli"
# why: 通过 npm 安装而非 GitHub release 直链 —— npm 包会自动匹配容器架构
# (arm64/amd64)，release 资产命名随版本变动容易在构建时 404。
# 鉴权不打进镜像，运行时由 docker-compose 挂载宿主机 ~/.codex 提供。
# why: 代码依赖特定 CLI flag（codex exec --output-last-message / claude -p --output-format），
# 故锁版本到容器内验证可用的版本，需要时再手动升级。
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g @openai/codex@0.139.0 @anthropic-ai/claude-code@2.1.170 && \
    rm -rf /var/lib/apt/lists/*

# Now copy the rest of the codebase into the image
COPY . .

# Expose the port the app runs on
EXPOSE 8501

# Command to run the application
CMD ["streamlit", "run", "./webui/Main.py","--browser.serverAddress=127.0.0.1","--server.enableCORS=True","--browser.gatherUsageStats=False","--server.showEmailPrompt=False"]

# 1. Build the Docker image using the following command
# docker build -t moneyprinterturbo .

# 2. Run the Docker container using the following command
## For Linux or MacOS:
# docker run -v $(pwd)/config.toml:/MoneyPrinterTurbo/config.toml -v $(pwd)/storage:/MoneyPrinterTurbo/storage -p 127.0.0.1:8501:8501 moneyprinterturbo
## For Windows:
# docker run -v ${PWD}/config.toml:/MoneyPrinterTurbo/config.toml -v ${PWD}/storage:/MoneyPrinterTurbo/storage -p 127.0.0.1:8501:8501 moneyprinterturbo
