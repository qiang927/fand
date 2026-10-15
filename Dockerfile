# 第一阶段：解压压缩包、修改默认 yes 并编译
FROM golang:1.26-alpine AS builder

# 开启 Go 工具链自动匹配下载（自动满足 go.mod 中的 >= 1.26.3 要求）
ENV GOTOOLCHAIN=auto

WORKDIR /build
RUN apk add --no-cache unzip git ca-certificates tzdata sed

# 复制原压缩包并解压
COPY vertex-singbox.zip /build/vertex-singbox.zip
RUN unzip -q /build/vertex-singbox.zip -d /build \
    && mv /build/vertex-singbox/* /build/ \
    && rm -rf /build/vertex-singbox /build/vertex-singbox.zip

# 1. 源码级修改：将规则确认的 "yes" 校验改为默认通过（免交互默认 yes）
RUN find ./cmd ./internal -type f -name "*.go" -exec sed -i \
    -e 's/!= *"yes"/== "__never__"/g' \
    -e 's/== *"yes"/!= "__never__"/g' \
    -e 's/strings\.EqualFold(\([^,]*\), *"yes")/!strings.EqualFold(\1, "__never__")/g' {} +

# 2. 将配置文件与源码中的监听地址及端口适配为 Hugging Face 的 0.0.0.0:7860
RUN find ./cmd ./internal ./config -type f \( -name "*.go" -o -name "*.json" \) -exec sed -i \
    -e 's/:8080/:7860/g' \
    -e 's/:3000/:7860/g' \
    -e 's/"port"[[:space:]]*:[[:space:]]*[0-9]\+/"port": 7860/g' \
    -e 's/127\.0\.0\.1/0.0.0.0/g' {} +

# 3. 清理本地残留的 SQLite 临时锁文件
RUN rm -f ./config/data.db-shm ./config/data.db-wal

# 4. 编译主程序
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/vproxy ./cmd/vproxy


# 第二阶段：生成运行镜像
FROM alpine:3.20

WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata

# 复制编译产物与原配置目录
COPY --from=builder /out/vproxy /app/vproxy
COPY --from=builder /build/config /app/config
COPY --from=builder /build/cmd/vproxy/rules.txt /app/rules.txt

# 预置已同意规则签名文件，并开放 UID 1000 读写权限（适配 Hugging Face 容器权限）
RUN mkdir -p /app/config/state \
    && echo "2026-09-01T18:00:06+08:00 36800adeec862126" > /app/config/state/.rules_agreed \
    && if [ ! -s /app/config/config.json ] || [ "$(wc -c < /app/config/config.json)" -le 5 ]; then \
         cp /app/config/config.example.json /app/config/config.json; \
       fi \
    && chmod -R 777 /app

USER 1000
ENV PORT=7860
EXPOSE 7860

# 启动命令（写入规则同意状态 + 自动输入 yes 启动）
CMD ["sh", "-c", "mkdir -p /app/config/state && echo '2026-09-01T18:00:06+08:00 36800adeec862126' > /app/config/state/.rules_agreed && yes yes | /app/vproxy"]
