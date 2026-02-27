# 在 EC2 上通过 LiteLLM 代理 Amazon Bedrock 部署指南

## 前提条件

- Amazon Linux 2023 EC2 实例（已安装 Docker）
- EC2 实例的 IAM Role 需要 Bedrock 权限

## 1. 配置 IAM 权限

如果 EC2 的 IAM Role 已达到 10 个托管策略上限，使用 inline policy 添加 Bedrock 权限：

```bash
aws iam put-role-policy \
  --role-name <your-ec2-role-name> \
  --policy-name BedrockAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Action": "bedrock:*", "Resource": "*"}]
  }'
```

## 2. 准备配置文件

创建 `/data/claude-code/config.yaml`：

```yaml
litellm_settings:
  modify_params: true
  drop_params: true

model_list:
  - model_name: claude-opus-4-6
    litellm_params:
      model: bedrock/us.anthropic.claude-opus-4-6-v1

  - model_name: claude-sonnet-4
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0

  # 按需添加更多模型...
```

关键配置说明：
- `modify_params: true` — 自动修正不兼容的参数（如 thinking blocks 缺失时自动处理）
- `drop_params: true` — 自动丢弃目标模型不支持的参数
- `claude-opus-4-6` 的模型 ID 是 `us.anthropic.claude-opus-4-6-v1`（支持 adaptive thinking），不要与旧版 `claude-opus-4-20250514` 混淆

## 3. 启动 LiteLLM

```bash
docker run -d -p 4000:4000 \
  -e LITELLM_MASTER_KEY=<your-master-key> \
  -e AWS_REGION=us-east-1 \
  -v /data/claude-code/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml
```

> 不要通过 `-e AWS_ACCESS_KEY_ID` 传递密钥，EC2 会通过 Instance Metadata 自动获取 IAM Role 凭证。

## 4. 验证服务

```bash
# 检查容器状态
docker ps

# 查看日志
docker logs <container-id>

# 测试 API
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer <your-master-key>"
```

## 5. Claude Code 的使用配置

**Claude Code 可以用于代码安全扫描**，扫描 GitHub 仓库中的代码。使用前需要先将目标仓库 clone 到本地，然后在仓库目录中启动 Claude Code。

### 5.1 克隆目标仓库

```bash
git clone <github-repo-url>
cd <repo-name>
```

### 5.2 设置环境变量

在使用 Claude Code 的客户端机器上设置环境变量：

```bash
export ANTHROPIC_BASE_URL="http://<ec2-private-ip>:4000"
export ANTHROPIC_API_KEY="<your-litellm-master-key>"
```

> 注意：URL 必须包含 `http://` 前缀，否则会报 URL 解析错误。`ANTHROPIC_API_KEY` 的值对应 LiteLLM 启动时设置的 `LITELLM_MASTER_KEY`。

**也可以通过编辑 `~/.claude/settings.json` 配置本地使用：**

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://<ec2-public-ip>:4000"
  },
  "model": "claude-opus-4-6",
  "apiKeyHelper": "echo <your-litellm-master-key>",
  "permissions": {
    "allow": [],
    "deny": []
  }
}
```

### 5.3 解决 git 报错

在某个 git 仓库目录中启动 Claude Code 时，可能遇到以下错误：

```
fatal: ambiguous argument 'origin/HEAD': unknown revision or path not in the working tree.
```

原因是仓库没有设置 `origin/HEAD`。在项目目录下执行：

```bash
git remote set-head origin main
```

> 如果默认分支不是 `main`，替换为实际的分支名（如 `master`）。

### 5.4 启动安全扫描

在仓库目录中启动 Claude Code 后，使用以下命令进行安全审查：

```bash
# 启动 Claude Code
claude

# 在 Claude Code 中执行安全审查
/security-review
```

`/security-review` 会扫描当前仓库代码，识别潜在的安全漏洞、敏感信息泄露、不安全的编码实践等问题。

## 6. 解决 Bedrock 不支持 adaptive thinking 的问题

### 问题描述

Claude Code 客户端会发送 `thinking.type: adaptive` 参数，但 Amazon Bedrock 只接受 `enabled` 或 `disabled`，导致 Sonnet 模型报错：

```
thinking: Input tag 'adaptive' found using 'type' does not match any of the expected tags: 'disabled', 'enabled'
```

> Opus 4.6 和 Haiku 不受影响，仅 Sonnet 系列（支持 extended thinking 的模型）会触发此问题。

### 原因

- Claude Code 更新后开始发送 `thinking.type: adaptive`（Anthropic API 原生支持）
- Bedrock 尚未支持 `adaptive` 类型
- LiteLLM v1.81.x 未做 `adaptive` → `enabled` 的自动转换

### 解决方案：Python 代理中间层

在 LiteLLM 前面加一层轻量代理，拦截请求并将 `thinking.type: adaptive` 改写为 `thinking.type: enabled`。

**步骤 1**：将 LiteLLM 改为监听 4001 端口（代理占用 4000）

```bash
docker run -d -p 4001:4000 \
  -e LITELLM_MASTER_KEY=<your-master-key> \
  -e AWS_REGION=us-east-1 \
  -v /data/claude-code/config.yaml:/app/config.yaml \
  --name litellm-backend \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml
```

**步骤 2**：创建代理脚本 `/data/claude-code/proxy.py`

```python
"""Thin proxy: rewrites thinking.type 'adaptive' → 'enabled' before forwarding to LiteLLM."""

import json
from aiohttp import web, ClientSession

BACKEND = "http://127.0.0.1:4001"

async def proxy(request: web.Request) -> web.StreamResponse:
    url = f"{BACKEND}{request.path_qs}"
    headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}

    body = await request.read()
    if body and request.content_type == "application/json":
        try:
            data = json.loads(body)
            thinking = data.get("thinking")
            if isinstance(thinking, dict) and thinking.get("type") == "adaptive":
                thinking["type"] = "enabled"
                thinking.setdefault("budget_tokens", 10000)
            body = json.dumps(data).encode()
            headers["content-length"] = str(len(body))
        except (json.JSONDecodeError, KeyError):
            pass

    async with ClientSession() as session:
        async with session.request(request.method, url, headers=headers, data=body) as resp:
            if resp.headers.get("transfer-encoding", "").lower() == "chunked" or "text/event-stream" in resp.content_type:
                response = web.StreamResponse(status=resp.status, headers={
                    k: v for k, v in resp.headers.items()
                    if k.lower() not in ("transfer-encoding", "content-length")
                })
                response.content_type = resp.content_type
                await response.prepare(request)
                async for chunk in resp.content.iter_any():
                    await response.write(chunk)
                await response.write_eof()
                return response
            else:
                return web.Response(status=resp.status, body=await resp.read(),
                                    headers={k: v for k, v in resp.headers.items() if k.lower() != "transfer-encoding"})

app = web.Application()
app.router.add_route("*", "/{path:.*}", proxy)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=4000)
```

**步骤 3**：安装依赖并启动代理

```bash
pip install aiohttp
nohup python3 /data/claude-code/proxy.py > /data/claude-code/proxy.log 2>&1 &
```

**架构**：

```
Claude Code → :4000 (proxy.py) → :4001 (LiteLLM) → Bedrock
```

> 当 LiteLLM 未来版本修复了 adaptive thinking 的转换后，可以去掉代理，将 LiteLLM 改回 4000 端口直接使用。

## 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `invalid beta flag` | LiteLLM 版本太旧，不支持新的 beta headers | 拉取最新镜像 `docker pull ghcr.io/berriai/litellm:main-latest` |
| `thinking type 'adaptive' does not match` | Bedrock 不支持 adaptive thinking，LiteLLM 未做转换 | 部署代理中间层（见步骤 6） |
| `403 not authorized bedrock:InvokeModelWithResponseStream` | IAM Role 缺少 Bedrock 权限 | 添加 Bedrock 权限策略（见步骤 1） |
| URL cannot be parsed | 客户端 API 地址缺少 `http://` 前缀 | 补全协议前缀 |
