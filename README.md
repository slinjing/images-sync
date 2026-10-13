# Docker 镜像同步工具
基于 GitHub Actions 自动批量拉取 Docker 镜像，并转推至私有镜像仓库。
支持并发同步、失败重试、日志记录；修改镜像列表自动触发、支持手动执行 + 定时全量同步。

## ✨ 功能特性
- ✅ **并发拉取推送**：可自定义并发数量，加速大批量镜像同步
- ✅ **失败自动重试**：拉取/推送失败自动重试，减少网络抖动导致任务失败
- 📝 **日志持久化**：生成成功/失败日志，任务结束自动上传日志文件，保留7天
- ❌ **失败标记Job**：只要任意镜像同步失败，整个 GitHub Action 任务标记为失败（红色）
- ⏰ **多种触发方式**
  1. 修改镜像列表文件，自动触发同步
  2. GitHub 网页手动点击运行
  3. 定时每日自动全量同步
- ✅ 📄 **注释支持**：镜像列表文件支持 `#` 注释，方便分组管理镜像

## 📁 仓库文件说明
```bash
├── .github/workflows/
│   └── images-sync.yaml     # GitHub Actions 工作流配置文件
├── app.sh                   # 镜像同步核心脚本
├── images.yaml              # 镜像清单（一行一个镜像，# 开头为注释）
└── README.md                # 项目说明文档
```


## ⚙️ 前置准备
### 1. 私有镜像仓库 Secrets 配置
进入仓库 `Settings → Secrets and variables → Actions → New repository secret`，添加下面3个密钥：
| Secret 名称 | 说明 |
| ---- | ---- |
| `REGISTRY` | 目标私有镜像仓库地址，例如 `cr.example.com` |
| `REGISTRY_USER` | 镜像仓库登录用户名 |
| `REGISTRY_PASSWORD` | 镜像仓库登录密码 / Token |
| `REGISTRY_NAMESPACE` | 仓库命名空间（组织/项目名称） |

> 脚本会自动将源镜像重命名为：`${REGISTRY}/${REGISTRY_NAMESPACE}/${镜像名}:标签`

### 2. 镜像列表 `images.yaml` 格式
一行填写一个完整镜像地址，`#` 为注释，用于分组归类，示例：
```yaml
## Linux 基础镜像
alpine:latest
ubuntu:24.04

## 数据库
mysql:8.0.39
redis:latest
```

## 🚀 使用方法

### 方式 1：自动触发

修改并提交 `images.yaml` 到 `main` 分支，GitHub Actions **自动执行镜像同步**。

> 
> 仅修改 `images.yaml` 文件才会触发，修改 app.sh、workflow 文件不会自动运行。

### 方式 2：手动触发

1. 仓库页面点击 `Actions`
2. 选中 `Image Sync`
3. 点击 `Run workflow`，选择 `main` 分支，启动任务

### 方式 3：定时自动同步

workflow 内置 cron 定时任务，默认 **UTC 每天 16 点** 自动执行一次全量镜像同步。

> 
> UTC 时间比北京时间晚 8 小时；如需北京时间 16 点执行，修改 cron 表达式为 `0 8 * * *`

## 🛠 脚本配置参数（app.sh）

打开 `app.sh`，顶部可调整：
```bash
CONCURRENCY=3     # 并发数量，推荐 2~4，根据镜像仓库限流调整
retries=3         # 拉取/推送失败最大重试次数
sleep 2           # 每次重试等待间隔（秒）
```

## 📊 查看运行结果

1. 进入仓库 `Actions`，打开 `Image Sync` 任务
2. 日志内查看 **同步汇总统计**：成功数量、失败数量 + 镜像清单
3. 任务工件 `sync-logs`：可以下载 `succeeded.log` / `failed.log` 详细日志，保留 7 天

## ❗ 失败排查

- 出现失败时，Job 标记红色，查看日志与 `failed.log`
- 常见原因：
  1. 源镜像名称写错、镜像在源仓库不存在
  2. 目标仓库账号权限不足，无法 push 镜像
  3. GitHub Runner 网络问题，拉取国外镜像超时（可降低并发，增大重试间隔）
  4. 镜像仓库限流，并发过高导致推送失败，调低 `CONCURRENCY`

## 📌 注意事项

1. 镜像同步会完整拉取镜像到 GitHub 临时 Runner，**流量大**，大量大镜像注意执行时长限制，当前超时设置 60 分钟
2. 定时任务会 **全量重新同步列表内所有镜像**，无论镜像是否已经存在于目标仓库
3. GitHub 免费账号 Action 有每月运行时长配额，大批量镜像注意控制任务频次
4. 日志 artifact 默认保留 7 天，到期自动删除
