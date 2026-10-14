# Docker镜像批量同步工具

> GitHub‑Actions批量同步镜像到私有仓库(阿里云ACR/腾讯TCR/Harbor)
> 规则：`latest`每次强制同步；非‑latest检测目标已存在则跳过，不下载镜像。
> 底层：`docker pull‑tag‑push`，`crane`仅用来查询镜像元信息。

## ✨功能
- latest标签每次强制同步
- 非‑latest增量跳过，节省流量磁盘
- 镜像不写tag自动补`:latest`
- 支持并发、拉取推送自动重试
- 输出三份日志：`succeeded.log`/`skipped.log`/`failed.log`，自动上传保留7天
- 终端彩色输出；下载的日志文件无颜色码，不会乱码
- 修改清单自动触发、手动运行、定时执行
- 每行镜像支持`#`注释分组

> ⚠️注意：使用docker本地拉取镜像，runner磁盘上限20G；大镜像多把并发改为`1`串行。

## 📁文件结构
```

├── .github/workflows/
│   └── images-sync.yaml
├── app.sh
├── images.yaml
└── README.md

```

## ⚙️ Secrets配置
仓库 Settings → Secrets and variables → Actions 添加密钥

| Secret | 说明 |
|---|---|
| REGISTRY | 私有仓库地址 |
| REGISTRY_USER | 仓库访问凭证用户名 |
| REGISTRY_PASSWORD | 仓库访问凭证密码 |
| REGISTRY_NAMESPACE | 命名空间/项目名 |

> 镜像转换：源镜像 → `${REGISTRY}/${REGISTRY_NAMESPACE}/${短镜像名}:tag`

## 📝 images.yaml示例
```yaml
## 基础镜像
alpine:latest
ubuntu:24.04
redis
## 数据库
mysql:8.0.39
```

## 🚀运行方式

1. **自动触发**：提交修改`images.yaml`到 main 分支自动运行
2. **手动运行**：Actions → Image Sync → Run workflow
3. **定时**：workflow 中 cron `30 8 * * *`（UTC 08:30 = 北京时间 16:30）

## 🛠参数（在 images‑sync.yaml 的 env 修改，不用改脚本）

```
env:
  CONCURRENCY: 2    # 并发，大镜像改为1
  RETRIES: 3        # 重试次数
  SLEEP_RETRY: 2    # 重试间隔秒
```

## 📊查看结果

1. Actions 网页日志：查看成功、跳过、失败统计与清单
2. Artifact `sync‑logs`下载三份日志文件

## 🔑执行逻辑

1. 无 tag → 自动补`:latest`，强制同步
2. tag=latest：直接同步，不查询目标仓库
3. tag 非 latest：crane 查询目标
   - 返回 0：镜像已存在，直接跳过，不 pull
   - 非 0 (不存在 / 网络异常)：完整执行同步流程

## ❗常见问题

1. **磁盘爆满**：设置`CONCURRENCY:1`串行执行
2. **PULL_FAIL 拉取失败**：境外源网络波动，调大重试，降低并发
3. **AWS‑ECR**：需要提前手动建立仓库，不支持自动创建；ACR/TCR/Harbor 自动建库

> 
> GitHub 免费账号注意 Actions 时长配额，控制定时任务频次。
