# 2026-11-16 迁移备份

本分支 `migration-2026-11-16` 保存从 Ubuntu 22.04 迁往 Red Hat 8 前的项目状态。现有 `pa2`、`branch-v3-20261001` 等开发分支保持原样；当前未提交修改放在本迁移快照中。

- `source/ysyx/ysyx-workbench/`：RV64 主工作目录，包括 NEMU、AM、NPC 和依赖的当前源码。
- `source/ysyx/ysyx-workbench-rv32-interview/`：RV32 工作目录。
- `source/ysyx/ysyx-workbench-rv32-baseline-replay/`：baseline 实验目录。
- `source/ysyx/learn-c-the-hard-way-lectures/`：C 练习修改。
- `metadata/`：各目录的暂存/未暂存补丁和原 Git 状态。
- `PROJECT-MANIFEST.json`：23 个工作目录/依赖的原 HEAD、分支、远程和历史备份映射。
- `migration-history-2026-11-16/*` 分支：主仓库本地分支历史，以及存在本地修改的依赖仓库历史。所有历史保存在本用户的 ysyx 仓库，不向第三方上游写入。

## 在新机恢复

```bash
git clone --single-branch -b migration-2026-11-16 https://github.com/roundeodo/ysyx.git ~/ysyx-migration
cd ~/ysyx-migration
python3 restore.py ~/ysyx-restored
```

目标目录必须为空。恢复结果在 `~/ysyx-restored/ysyx/`。原来共用 Git worktree 元数据的工作目录会恢复成独立仓库，不依赖旧机绝对路径。主项目和有修改依赖的原 HEAD、分支、暂存及未暂存状态会恢复；没有修改的第三方依赖保留完整当前源码，完整 Git 历史可按 manifest 中的 origin/HEAD 另行获取。

只取源码、不恢复 Git 历史可用 `python3 restore.py ~/ysyx-restored --source-only`。如新机已经存在 `~/ysyx`，先检查并另存原有目录，再安排恢复结果的位置。若沿用旧项目路径，可把恢复结果的 `ysyx` 目录放到 home 下，使主工程为 `~/ysyx/ysyx-workbench`。

```bash
git clone https://github.com/roundeodo/dotfiles.git ~/dotfiles
cd ~/dotfiles
python3 install.py
python3 install.py --apply
```

配置安装脚本会保留 Red Hat 的 Bash 初始化。格式化、补全、仿真、综合是否正常仍需在新系统核对预装工具的版本和路径。

## 保存范围

保存存在的受 Git 管理文件、非忽略的手写文件，以及生成目录以外额外识别出的配置、SDC/Tcl 约束、文档、实验 JSON/CSV 和相关库文件。Git 忽略的 build/result/out 等大型产物目录、波形、缓存、C 练习编译产物和 core dump 不保存。这里是源码与修改备份，不是完整旧虚拟机镜像，也不表示未完成的实验已经通过功能验证。

SSH/GPG 私钥、账号令牌、Cookie 和登录数据库不上传。第三方 Capstone 模糊测试脚本中的一处既有硬编码服务密钥在本快照中改为从环境变量读取，见 `SANITIZATION.json`；原虚拟机文件未修改。
