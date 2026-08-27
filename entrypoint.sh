#!/bin/sh
set -e

# Scaleway 会在部署时自动注入 PORT，本地调试时给个默认值
export PORT="${PORT:-8080}"

# 必须由部署时的环境变量提供，缺失就直接失败退出，避免用空 UUID 起服务
if [ -z "${UUID}" ]; then
  echo "ERROR: env UUID is required (VLESS user uuid). Deploy with -e UUID=xxxx-xxxx-...." >&2
  exit 1
fi

export WS_PATH="${WS_PATH:-/ws}"
export LOG_LEVEL="${LOG_LEVEL:-warn}"

echo "Starting sing-box: PORT=${PORT} WS_PATH=${WS_PATH} LOG_LEVEL=${LOG_LEVEL} GOMAXPROCS=${GOMAXPROCS} GOMEMLIMIT=${GOMEMLIMIT}"

mkdir -p /etc/sing-box

# busybox 没有 envsubst，用 sed 替换自定义占位符（@XXX@），
# 比 envsubst 更可控：只替换我们指定的几个 token，不会误伤 JSON 里其他 $ 字符
sed -e "s/@PORT@/${PORT}/g" \
    -e "s/@UUID@/${UUID}/g" \
    -e "s#@WS_PATH@#${WS_PATH}#g" \
    -e "s/@LOG_LEVEL@/${LOG_LEVEL}/g" \
    /etc/sing-box/config.template.json > /etc/sing-box/config.json

# 打印出去除敏感信息后的配置，便于在平台日志里排查启动问题
sed 's/"uuid": ".*"/"uuid": "***"/' /etc/sing-box/config.json

exec sing-box run -c /etc/sing-box/config.json
