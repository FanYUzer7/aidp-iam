# Rubik 前后端部署指南（Kind 模式）

> 本指南介绍如何在 Kind 集群中部署 Rubik 前端和后端服务。

## 架构概览

```
Browser → rubik-frontend (NodePort:30080)
              │
              ├── /           → SPA 静态文件
              ├── /kbApi/*    → rubik-backend:43211
              ├── /api/v1/*  → AgentGateway:80 (IAM)
              └── /realms/*  → AgentGateway:80 → Keycloak
```

| 服务 | 端口 | 说明 |
|------|------|------|
| rubik-frontend | 32777 (container) / 30080 (NodePort) | 前端页面 |
| rubik-backend | 43211 | 后端 API |
| AgentGateway | 80 | IAM 网关入口 |
| Keycloak | 8080 | OIDC 提供者 |

---

## 前置条件

- Docker 已安装
- `kind` 工具已安装
- `kubectl` 已安装
- `dataagent:20260318` 基础镜像已存在

---

## 第一步：确认基础镜像

```bash
docker images | grep dataagent
```

如果没有，需要先拉取或构建基础镜像。

---

## 第二步：构建 rubik-backend 镜像

```bash
cd /home/youya/workspace/aidp-iam/da-cluster/images/rubik-backend

# 构建新镜像
docker build -t rubik-backend:latest .

# 或者如果 backend 代码已内置在 dataagent 中，直接 tag
docker tag dataagent:20260318 rubik-backend:latest
```

---

## 第三步：构建 rubik-frontend 镜像

```bash
cd /home/youya/workspace/aidp-iam/da-cluster/images/rubik-frontend

# 构建时通过 ARG 修改 vite.config.ts 中的 proxy target
# 默认 target 是 http://rubik-backend:43211/api
docker build -t rubik-frontend:latest \
  --build-arg RUBIK_BACKEND_URL=http://rubik-backend:43211/api .
```

---

## 第四步：创建 Kind 集群（如果还没有）

```bash
# 创建集群
kind create cluster --name da-cluster --wait 60s

# 确认集群可用
kubectl cluster-info --context kind-da-cluster
```

---

## 第五步：加载镜像到 Kind

```bash
# 加载 backend 镜像
kind load docker-image rubik-backend:latest --name da-cluster

# 加载 frontend 镜像
kind load docker-image rubik-frontend:latest --name da-cluster
```

---

## 第六步：创建 namespace

```bash
kubectl create namespace rubik
```

---

## 第七步：部署 rubik-backend

### 方式 A - 直接用 kubectl

```bash
# 确保 deployment.yaml 中的 image 为 rubik-backend:latest
sed -i 's|image: docker.io/library/rubik-backend:latest|image: rubik-backend:latest|' \
  /home/youya/workspace/aidp-iam/da-cluster/images/rubik-backend/k8s/deployment.yaml

# 部署
kubectl apply -f /home/youya/workspace/aidp-iam/da-cluster/images/rubik-backend/k8s/
```

### 方式 B - 用 Helm

```bash
helm upgrade -i rubik-backend \
  /home/youya/workspace/aidp-iam/da-cluster/images/rubik-backend/helm/rubik-backend \
  --namespace rubik
```

---

## 第八步：部署 rubik-frontend

### 方式 A - 直接用 kubectl

```bash
kubectl apply -f /home/youya/workspace/aidp-iam/da-cluster/images/rubik-frontend/k8s/
```

### 方式 B - 用 Helm

```bash
helm upgrade -i rubik-frontend \
  /home/youya/workspace/aidp-iam/da-cluster/images/rubik-frontend/helm/rubik-frontend \
  --namespace rubik
```

---

## 第九步：暴露 frontend NodePort（用于测试）

```bash
# 将 frontend 服务改为 NodePort，端口 30080
kubectl patch svc rubik-frontend -n rubik -p '{
  "spec": {
    "type": "NodePort",
    "ports": [{"port":80,"nodePort":30080}]
  }
}'
```

---

## 第十步：验证部署

```bash
# 检查 pod 状态
kubectl get pods -n rubik

# 查看所有服务
kubectl get svc -n rubik

# 本地端口转发测试（可选）
kubectl port-forward svc/rubik-frontend 8080:80 -n rubik

# 验证 backend 是否正常
curl http://localhost:8080/kbApi/xxx
```

---

## 常用运维操作

### 更新镜像

如果更新了镜像代码，需要重新加载并重启 pod：

```bash
# 1. 重新 build（如果有代码更新）
docker build -t rubik-backend:latest ./da-cluster/images/rubik-backend

# 2. 重新加载到 Kind
kind load docker-image rubik-backend:latest --name da-cluster

# 3. 重启 pod
kubectl rollout restart deployment rubik-backend -n rubik
kubectl rollout restart deployment rubik-frontend -n rubik

# 或者直接删除 pod
kubectl delete pod -n rubik -l app=rubik-backend
```

### 删除 Kind 中的镜像

Kind 没有直接的 `unload` 命令，需要通过 containerd 删除：

```bash
# 1. 找到 Kind 节点容器名
docker ps --format '{{.Names}}' | grep kind

# 2. 用 ctr 删除镜像（单节点）
docker exec -it da-cluster-control-plane \
  ctr -n k8s.io images rm rubik-backend:latest
```

### 删除整个集群

```bash
kind delete cluster --name da-cluster
```

---

## 注意事项

1. **端口不匹配问题**：当前 `nginx.conf` 中 `/kbApi/` 代理到 `43252`，但 backend 暴露的是 `43211`。需要统一。

2. **IAM 依赖**：如果需要 OIDC 登录，需要先部署 AgentGateway + Keycloak（运行 `./scripts/setup.sh`）。

3. **网络策略**：生产环境需要配置网络策略限制 `rubik-backend` 只允许 `rubik-frontend` 访问。
