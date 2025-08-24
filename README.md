# 镜像同步工具

## 简介

本工具用于将指定的Docker镜像自动同步到目标镜像仓库，支持通过配置文件定义需同步的镜像列表，并借助GitHub Actions实现自动化同步流程。适用于需要批量管理和同步镜像的场景，确保关键镜像在目标仓库的可用性。

## 配置说明

### 1. 环境变量与密钥配置

在GitHub仓库的`Settings > Secrets and variables > Actions`中配置以下密钥（Secrets）：

| 密钥名称           | 说明                          | 示例值                              |
|--------------------|-------------------------------|-----------------------------------|
| `REGISTRY`         | 目标镜像仓库地址              | `registry.cn-beijing.aliyuncs.com`|
| `REGISTRY_USER`    | 目标仓库登录用户名            | `your-username`                   |
| `REGISTRY_PASSWORD`| 目标仓库登录密码/访问令牌     | `your-password`                   |
| `REGISTRY_NAMESPACE`| 目标仓库的命名空间（可选）    | `your-namespace`                  |


### 2. 镜像列表配置（`images.yaml`）

用于定义需要同步的镜像，格式规则：
- 每行填写一个镜像，格式为 `[仓库地址/]镜像名:标签`（标签默认`latest`）
- 以 `#` 开头的行视为注释，会被忽略
- 空行会自动跳过

示例：
```yaml
# 基础镜像
nvidia/cuda:12.4.1-devel-ubuntu22.04

# 注释的镜像（不会被同步）
# linuxserver/qbittorrent:5.1.2

# 数据库镜像
# postgis/postgis:16-3.4-alpine
# mysql:latest
```


## 使用方法

### 本地手动同步

1. 确保已安装Docker并登录目标仓库：
   ```bash
   docker login $REGISTRY -u $REGISTRY_USER -p $REGISTRY_PASSWORD
   ```

2. 配置环境变量：
   ```bash
   export REGISTRY="目标仓库地址"
   export NAMESPACE="目标命名空间"  # 若目标仓库无需命名空间可省略
   ```

3. 执行同步脚本：
   ```bash
   chmod +x app.sh
   ./app.sh
   ```


### 自动同步（GitHub Actions）

1. 将代码推送到GitHub仓库的`main`分支
2. 当`images.yaml`文件发生变更时，会自动触发同步工作流
3. 也可在GitHub仓库的`Actions`页面，手动触发`Image Synchr`工作流


## 同步流程说明

1. 脚本读取`images.yaml`，过滤注释和空行，获取需同步的镜像列表
2. 对每个镜像执行以下操作：
   - 解析镜像名称（提取最后一级路径作为目标名称）和标签
   - 拉取原始镜像（`docker pull`）
   - 为镜像打上目标仓库标签（`docker tag`），格式：`${REGISTRY}/${NAMESPACE}/${镜像名}:${标签}`
   - 推送标签后的镜像到目标仓库（`docker push`）
3. 同步成功的镜像会记录到`succeeded.log`
4. 若任一环节失败（拉取、打标签、推送），脚本会立即终止并输出错误信息


## 注意事项

1. 确保目标仓库已开通并授予推送权限，否则会导致推送失败
2. 镜像同步依赖网络环境，大型镜像可能需要较长时间，可在`images-sync.yaml`中调整超时设置（默认无显式超时）
3. 若同步失败，可通过GitHub Actions工作流日志或本地执行输出定位问题（常见原因：网络波动、镜像不存在、权限不足）
4. `images.yaml`中注释的镜像不会被同步，可通过注释临时禁用不需要的镜像
5. 脚本采用串行处理方式，一个镜像处理完成后才会开始下一个（如需并行处理可参考优化方案）


## 常见问题

- **Q：镜像名称解析规则是什么？**  
  A：例如`ghcr.io/openrailassociation/osrd-edge/osrd-core:dev`会被解析为名称`osrd-core`，标签`dev`，目标镜像为`${REGISTRY}/${NAMESPACE}/osrd-core:dev`。

- **Q：如何查看同步结果？**  
  A：本地执行时查看`succeeded.log`；GitHub Actions中可在工作流的`Succeeded`步骤查看日志。

- **Q：同步失败后如何重试？**  
  A：本地可直接重新执行`./app.sh`；GitHub Actions中可在工作流页面点击`Re-run jobs`重试。
