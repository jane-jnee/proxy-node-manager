# 定制节点管理 v2.1.1

适用：自有 Linux 服务器。无广告，支持 VLESS + TCP + Reality、VMess + WebSocket、Shadowsocks；每种协议可以创建多条独立节点。

## v2.1.1 兼容性修复（2026-10-29）

修复 Ubuntu 22.04 常见 nftables 1.0.2 的流量服务启动失败：旧版本的 JSON 输出不含表注释，旧校验会报“流量表的归属、对象或数值异常”。当且仅当 JSON 缺少该字段时，新版独立读取原生输出，核对表名、family、handle 和表级归属注释，再继续原有链、规则和额度校验。已有 JSON 明确显示错误或空归属时仍拒绝运行。

不删除流量状态、不清零用量、不清空防火墙。累计额度及手动重置行为保持原样。

出现上述报错时，先停止失败重试，再执行本仓库更新入口：

```bash
systemctl stop proxy-node-quota.service
bash <(curl -fsSL https://raw.githubusercontent.com/jane-jnee/proxy-node-manager/main/installer.sh)
```

菜单标题应显示 **v2.1.1**。先选 **13** 恢复并查看流量服务；若先前新增流程被中断，服务恢复后再选 **1** 新增该节点。已有节点不必删除或重新创建，也不要选 15 清零。实际 Linux 服务恢复结果仍需在目标服务器确认。

## 新增功能

- 每次新增 1–20 条同协议节点，每条有独立名称、端口和 UUID/密码；Reality 另有独立密钥及 short ID。
- 新建时逐条设置累计流量额度，也可以后单独调整。`100` 表示 100 GB，`0.5` 表示 500 MB，`0` 表示不限量；最多三位小数。
- 上传与下载合计；1 GB = 1,000,000,000 字节。额度用完后阻断该节点的网络流量，不影响其他节点的额度。
- 采用累计额度，**不按月自动清零**。只有菜单中明确执行手动清零才重新开始累计。
- 修改端口、轮换凭据、重启服务、重新打开菜单均保留用量。改额度也保留用量；新额度低于已用量时保持阻断。
- 手动清零只作用于选中节点，额度数值保留。已断开的客户端可能需要重新连接。
- 安装后输入 `menu` 打开本地定制版。原来同路径的菜单文件会先备份，之后不再重新下载原广告脚本。

## 安装与打开菜单

发布仓库：[jane-jnee/proxy-node-manager](https://github.com/jane-jnee/proxy-node-manager)。

`installer.sh` 上传到该仓库后，可在自有 Linux 服务器执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jane-jnee/proxy-node-manager/main/installer.sh)
```

它是自包含的单文件启动器，会先在私有临时目录展开管理脚本，再安装本地 `menu` 入口。后续输入：

```bash
menu
```

菜单 1–3 新增节点；菜单 5 导出链接/二维码；菜单 13 启用流量管理并查看用量；菜单 14 修改选中节点额度；菜单 15 手动清零选中节点。

也可以将本包的 `installer.sh` 或 `proxy-node-manager.sh` 上传到 `/root/`，执行 `bash /root/installer.sh` 或 `bash /root/proxy-node-manager.sh`，效果相同。

如果原来的 `menu` 在其他目录，且当前 shell 仍缓存旧路径，执行一次 `hash -r` 后再输入 `menu`。`command -v menu` 应指向 `/usr/local/bin/menu`。

`installer.sh` 和 `proxy-node-manager.sh` 都不含你的服务器密码、节点密钥或节点配置，可以作为代码发布。运行后生成的 `/etc/sing-box/` 内容、备份和流量记录属于服务器私有数据，不要上传到公开仓库。

原来 `dabadabader/install` 的网址仍属于原作者；本定制版使用上面的仓库和 Raw 地址。准备本发布包不表示已完成公开上传或 VPS 部署。

## 流量管理的运行条件

自动流量管理需要 **systemd + nftables**，使用标准位置：

```text
/etc/sing-box/sing-box
/etc/sing-box/config.json
/etc/sing-box/node-manager/
/usr/local/lib/proxy-node-manager/manager.sh
```

脚本先检查 nftables JSON、命名额度与计数器能力；通过后才安装流量服务。使用独立的 `inet pnm_traffic` 表，不清空系统其他防火墙规则，也不会替你放行云安全组端口。OpenRC 可以使用原有节点管理功能，但本版不自动安装流量额度服务。

统计从**启用流量管理时**开始，无法补算之前的历史流量。仅管理本工具创建的独立端口节点；原脚本已有节点继续保留为只读，不自动套用限额。同一台服务器多条节点，默认共用其出口 IP。

计量是客户端与节点监听端口之间的网络字节，包含 IP/协议开销、重传及连接尝试；不等于纯下载文件大小，也不保证与云厂商账单完全一致。限额在内核按包执行，已超额的对象显示用量会停在额度边界，不继续作为无限累计账单统计。

适用于 sing-box 直接在宿主机监听独立端口的情况。Docker 转发、多个节点共用端口、其他进程使用同一端口，或特殊转发路由需要另行适配。

## 保存、恢复与异常处理

流量记录：

```text
/etc/sing-box/node-manager/traffic-state.json
```

每约 5 秒原子保存一次，正常结束时也会尝试保存。重启恢复先于代理服务启动；已有内核计数不会被较旧的磁盘记录覆盖。突然断电或强制终止可能丢失最近一次保存之后的少量用量；保存写入不代表具备精确计费系统的断电持久性。

手动清零会创建新的计数代次；单次清零中途失败后重试，不会反复授予新额度。配置回滚保留已消耗流量，流量状态不会随旧配置备份自动回退。

额度修改和配置更新时，会短暂阻断本工具管理的节点端口，以便保存用量和原子替换规则；普通配置修改还会重启 sing-box。不要将它描述为业务完全无感更新。

守护服务检查本工具的规则与对象是否完整；规则缺失时尝试恢复，无法读取、恢复或保存时尝试停止代理并报告错误。其他 root 程序删除防火墙规则仍可能在检查间隔内造成保护空窗，不能保证对外部修改绝对免疫。

检查服务：

```bash
systemctl status proxy-node-quota.service --no-pager
journalctl -u proxy-node-quota.service -n 50 --no-pager
systemctl status sing-box.service --no-pager
```

处理错误后，从 `menu` 的菜单 10 检查配置并恢复服务。不要删除 `traffic-state.json` 来处理错误，否则会失去累计用量依据。

每次节点配置修改保留完整配置/元数据事务备份；启动失败会尝试恢复。备份位置：

```text
/etc/sing-box/node-manager/backups/
```

`menu` 入口的旧文件备份位于 `/usr/local/bin/.menu-backup-时间.随机值/original`，旧管理脚本备份位于 `/usr/local/lib/proxy-node-manager/.manager-backup-时间.随机值/original`。

## 建议下一步再加的功能

1. 节点到期时间：适合给不同用户分配固定使用期限，与累计流量额度分别控制。
2. 批量导出：一次导出选中的多个节点，减少逐条复制。
3. 完整备份/恢复入口：同时备份配置、元数据和最新用量，避免只恢复节点却遗漏累计流量。

本版没有把这些建议冒充成已经实现的功能；也没有给服务器自动开放新的 Web 管理端口。

## 验证边界与来源

本次在隔离临时目录检查配置、链接、用量状态机、失败恢复和入口安装；Linux 防火墙/服务边界由模拟器替代。另使用官方 sing-box 1.14.4 Windows 主程序检查九条三协议样例入站配置。

**尚未在你的 Linux VPS 上安装或实际跑满流量测试**；目标服务器首次使用时仍需验证额度耗尽、单节点清零、其他节点不受影响、重启后用量保留。运行前的 `nft -c -f` 能力检查和应用后 JSON 核验也会在目标主机执行。

原方案来源：<https://github.com/dabadabader/install>。这是独立定制版，不会修改原仓库。

实现依据：[nftables 命名额度](https://wiki.nftables.org/wiki-nftables/index.php/Quotas)、[nft 命令文档](https://netfilter.org/projects/nftables/manpage.html)、[nft JSON 格式](https://manpages.debian.org/trixie/libnftables1/libnftables-json.5.en.html)、[sing-box 官方发布](https://github.com/SagerNet/sing-box/releases)。
