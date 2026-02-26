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

## 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `invalid beta flag` | LiteLLM 版本太旧，不支持新的 beta headers | 拉取最新镜像 `docker pull ghcr.io/berriai/litellm:main-latest` |
| `thinking type 'adaptive' does not match` | 模型 ID 错误，旧版 Opus 4 不支持 adaptive thinking | 使用 `us.anthropic.claude-opus-4-6-v1` |
| `403 not authorized bedrock:InvokeModelWithResponseStream` | IAM Role 缺少 Bedrock 权限 | 添加 Bedrock 权限策略（见步骤 1） |
| URL cannot be parsed | 客户端 API 地址缺少 `http://` 前缀 | 补全协议前缀 |
